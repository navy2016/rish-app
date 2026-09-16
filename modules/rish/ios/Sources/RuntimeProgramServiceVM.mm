#import "RuntimeProgramServiceVM.h"
#import "RuntimeEnvironmentStore.h"
#import "RuntimeWorkspaceSnapshot.h"
#import "LocalGuestModule.h"
#import "DSHGuestRuntimeState.h"
#import <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <unistd.h>
#include "rish.h"

static BOOL WriteAll(int fd, const void *data, NSUInteger size) {
  NSUInteger done = 0;
  while (done < size) {
    ssize_t count = write(fd, (const uint8_t *)data + done, size - done);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) return NO;
    done += (NSUInteger)count;
  }
  return YES;
}

static BOOL WriteEntry(int fd, uint32_t inode, uint32_t mode, NSString *name, NSData *data) {
  NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding];
  uint32_t fields[] = {inode, mode, 0, 0, 1, 0, (uint32_t)data.length,
      0, 0, 0, 0, (uint32_t)nameData.length + 1, 0};
  char header[111] = "070701";
  for (NSUInteger i = 0; i < 13; i++) snprintf(header + 6 + i * 8, 9, "%08x", fields[i]);
  uint8_t zeroes[4] = {};
  return WriteAll(fd, header, 110) && WriteAll(fd, nameData.bytes, nameData.length) &&
      WriteAll(fd, zeroes, 1) && WriteAll(fd, zeroes, (4 - (111 + nameData.length) % 4) % 4) &&
      WriteAll(fd, data.bytes, data.length) && WriteAll(fd, zeroes, (4 - data.length % 4) % 4);
}

static NSString *HashFile(NSURL *url) {
  int fd = open(url.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0) return nil;
  CC_SHA256_CTX context;
  CC_SHA256_Init(&context);
  uint8_t bytes[65536]; ssize_t count;
  while ((count = read(fd, bytes, sizeof(bytes))) > 0) CC_SHA256_Update(&context, bytes, (CC_LONG)count);
  close(fd);
  if (count < 0) return nil;
  uint8_t digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest, &context);
  NSMutableString *hex = [NSMutableString string];
  for (NSUInteger i = 0; i < sizeof(digest); i++) [hex appendFormat:@"%02x", digest[i]];
  return hex;
}

static NSURL *Overlay(NSURL *base, DSHRuntimeWorkspaceSnapshot *snapshot) {
  NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
      [NSString stringWithFormat:@"rish-program-%@.cpio", NSUUID.UUID.UUIDString]]];
  int output = open(url.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (output < 0) return nil;
  if (![NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey:NSFileProtectionComplete}
      ofItemAtPath:url.path error:nil]) {
    close(output); [NSFileManager.defaultManager removeItemAtURL:url error:nil]; return nil;
  }
  int input = open(base.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  BOOL okay = input >= 0;
  uint8_t buffer[65536]; ssize_t count = 0;
  while (okay && (count = read(input, buffer, sizeof(buffer))) > 0)
    okay = WriteAll(output, buffer, (NSUInteger)count);
  if (count < 0) okay = NO;
  if (input >= 0) close(input);
  uint32_t inode = 1;
  if (okay) okay = WriteEntry(output, inode++, 0040700, @"tmp/rish-workspace", NSData.data);
  for (NSDictionary *entry in snapshot.entries) {
    if (!okay) break;
    okay = WriteEntry(output, inode++, ([entry[@"directory"] boolValue] ? 0040000 : 0100000) |
        [entry[@"mode"] unsignedIntValue], [@"tmp/rish-workspace/" stringByAppendingString:entry[@"path"]],
        entry[@"data"]);
  }
  if (okay) okay = WriteEntry(output, inode, 0, @"TRAILER!!!", NSData.data);
  if (okay) okay = fsync(output) == 0;
  if (close(output)) okay = NO;
  if (okay) okay = [NSFileManager.defaultManager setAttributes:@{
      NSFileProtectionKey:NSFileProtectionComplete, NSFilePosixPermissions:@0600,
    } ofItemAtPath:url.path error:nil];
  if (!okay) { [NSFileManager.defaultManager removeItemAtURL:url error:nil]; return nil; }
  return url;
}

static NSDictionary *DecodeReply(char *raw) {
  if (raw == NULL) return nil;
  size_t size = strnlen(raw, 2 * 1024 * 1024 + 1);
  NSData *data = size <= 2 * 1024 * 1024 ? [NSData dataWithBytes:raw length:size] : nil;
  rish_string_free(raw);
  id reply = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  return [reply isKindOfClass:NSDictionary.class] ? reply : nil;
}

static void OnOutput(void *context, const char *bytes, size_t size) {
  if (context == NULL || bytes == NULL || size == 0 || size > 12 * 1024 * 1024) return;
  @autoreleasepool {
    NSDictionary *event = [NSJSONSerialization JSONObjectWithData:
        [NSData dataWithBytes:bytes length:size] options:0 error:nil];
    if (![event isKindOfClass:NSDictionary.class] || ![event[@"protocol_version"] isEqual:@1] ||
        ![event[@"event"] isEqual:@"output"] ||
        ![@[@"stdout", @"stderr"] containsObject:event[@"channel"]] ||
        ![event[@"data_base64"] isKindOfClass:NSString.class]) return;
    NSData *data = [[NSData alloc] initWithBase64EncodedString:event[@"data_base64"] options:0];
    if (data) ((__bridge DSHRuntimeProgramOutput)context)(event[@"channel"], data);
  }
}

@interface DSHRuntimeProgramVM ()
@property(nonatomic, strong) NSBundle *bundle;
@property(nonatomic) void *cancelToken;
@property(nonatomic, readwrite, getter=isCancelled) BOOL cancelled;
@end

@implementation DSHRuntimeProgramVM
- (instancetype)initWithBundle:(NSBundle *)bundle {
  self = [super init];
  if (self) {
    _bundle = bundle;
    _cancelToken = rish_vm_cancel_new();
  }
  return self;
}
- (void)cancel {
  @synchronized (self) {
    self.cancelled = YES;
    if (self.cancelToken) rish_vm_cancel_request(self.cancelToken);
  }
}
- (BOOL)isCancelled { @synchronized (self) { return _cancelled; } }
- (void)dealloc {
  // Execution retains this object; dealloc cannot race its sole worker.
  if (_cancelToken) rish_vm_cancel_free(_cancelToken);
}
+ (NSArray<NSString *> *)commandForFamily:(NSString *)family entryPath:(NSString *)entryPath
                                     args:(NSArray<NSString *> *)args {
  NSDictionary *scripts = @{
    @"python": @"cd /workspace && exec /usr/bin/python3 -u \"$@\"",
    @"node": @"cd /workspace && exec /usr/bin/node \"$@\"",
    @"bun": @"cd /workspace && exec /usr/bin/bun run \"$@\"",
    // go run consumes leading .go arguments as more source files. Build the
    // selected entry first so every supplied argument reaches the program.
    @"go": @"cd /workspace || exit; source=$1; shift; /usr/bin/go build -o /tmp/rish-program \"$source\" && exec /tmp/rish-program \"$@\"",
    @"rust": @"cd /workspace || exit; source=$1; shift; /usr/bin/rustc \"$source\" -o /tmp/rish-program && exec /tmp/rish-program \"$@\"",
    @"java": [entryPath.pathExtension.lowercaseString isEqual:@"jar"]
        ? @"cd /workspace && exec /usr/bin/java -jar \"$@\""
        : @"cd /workspace && exec /usr/bin/java \"$@\"",
  };
  NSString *script = scripts[family];
  if (script == nil || !DSHRuntimeProgramValidPath(entryPath)) return nil;
  NSMutableArray *command = [NSMutableArray arrayWithArray:
      @[@"/bin/busybox", @"chroot", @"/runtime", @"/bin/sh", @"-c", script, @"rish-program",
        [@"/workspace/" stringByAppendingString:entryPath]]];
  [command addObjectsFromArray:args];
  return command;
}
+ (NSArray<NSString *> *)commandForManifest:(NSDictionary *)manifest entryPath:(NSString *)entryPath
                                      args:(NSArray<NSString *> *)args {
  if (![manifest isKindOfClass:NSDictionary.class] ||
      ![manifest[@"family"] isKindOfClass:NSString.class]) return nil;
  NSArray *command = [self commandForFamily:manifest[@"family"] entryPath:entryPath args:args];
  if (!command) return nil;
  // Shared by manual runs and Agent programs/services. This frozen Bun 1.4.0
  // disk omits simdutf's scalar fallback; an unsupported backend returns zero
  // progress for long-string scans. Its Westmere kernels are audited against
  // the guest's instruction handlers. Other imported disks keep their defaults.
  if ([manifest[@"family"] isEqual:@"bun"] && [manifest[@"disk_sha256"] isEqual:
      @"099fce34488a9e225ca59c4ae60c206a180495a648b20f82ccf4ffdae5ea2271"]) {
    NSMutableArray *configured = [command mutableCopy];
    configured[5] = [@"export SIMDUTF_FORCE_IMPLEMENTATION=westmere; "
        stringByAppendingString:command[5]];
    return configured;
  }
  return command;
}
+ (NSUInteger)executionTimeoutMillisecondsForFamily:(NSString *)family entryPath:(NSString *)entryPath {
  // Cold JDK source compilation exceeded ten minutes on the hosted runner.
  // Keep the extension scoped and bounded; this does not affect cancellation.
  return [family isEqual:@"java"] && DSHRuntimeProgramValidPath(entryPath) &&
      [entryPath.pathExtension.lowercaseString isEqual:@"java"] ? 1200000 : 600000;
}
- (NSNumber *)performWithLease:(DSHRuntimeEnvironmentLease *)lease snapshot:(DSHRuntimeWorkspaceSnapshot *)snapshot
                      operation:(DSHRuntimeVMOperation)operation error:(NSError **)error {
  if (!operation) { if (error) *error = DSHRuntimeProgramError(@"E_PROGRAM_INVALID_REQUEST"); return nil; }
  NSString *failure = nil;
  NSNumber *exitCode = nil;
  NSURL *overlay = nil;
  void *session = NULL;
  DSHGuestVMOwner *owner = nil;
  @try {
    do {
      if (!self.cancelToken) { failure = @"E_PROGRAM_UNAVAILABLE"; break; }
      if (self.cancelled) break;
      owner = [DSHGuestRuntimeState.sharedState acquireGuestOwner];
      if (!owner) { failure = @"E_PROGRAM_BUSY"; break; }
      NSURL *kernel = [self.bundle URLForResource:DSHGuestKernelResourceName withExtension:nil];
      NSURL *initrd = [self.bundle URLForResource:DSHGuestInitramfsResourceName withExtension:nil];
      if (!kernel || !initrd) { failure = @"E_PROGRAM_ASSETS_MISSING"; break; }
      if (![HashFile(kernel) isEqual:DSHGuestKernelSha256] ||
          ![HashFile(initrd) isEqual:DSHGuestInitramfsSha256] ||
          ![lease.manifest[@"kernel_sha256"] isEqual:DSHGuestKernelSha256]) {
        failure = @"E_PROGRAM_ASSET_INTEGRITY"; break;
      }
      overlay = Overlay(initrd, snapshot);
      if (!overlay) { failure = @"E_PROGRAM_STORAGE"; break; }
      if (self.cancelled) break;
      NSData *boot = [NSJSONSerialization dataWithJSONObject:@{
        @"kernel_path":kernel.path, @"initrd_path":overlay.path, @"root_disk_path":lease.diskURL.path,
        @"memory_mib":lease.manifest[@"minimum_memory_mib"], @"command":@[], @"network":@"user-nat",
        @"command_line":@"console=ttyS0,115200n8 rdinit=/init panic=-1 oops=panic nokaslr cgroup_no_v1=all 8250.nr_uarts=1",
        @"boot_budget_units":@80000000000ULL, @"handshake_budget_units":@80000000000ULL,
      } options:0 error:nil];
      session = boot ? rish_vm_boot_session_cancellable((const char *)boot.bytes, boot.length, self.cancelToken) : NULL;
      if (!session) { failure = @"E_PROGRAM_BOOT"; break; }
      [DSHGuestRuntimeState.sharedState setGuestRuntimeMounted:YES owner:owner];
      if (self.cancelled) break;
      // This is constant application-owned shell text. Workspace names, file
      // contents and user argv are never interpolated into control commands.
      // The minimal guest has no init service that raises loopback. Both
      // language servers and their in-guest HTTP clients require it explicitly.
      NSString *setup = @"set -eu; /bin/busybox ip link set lo up; "
          "mkdir -p /runtime; mount -t ext4 /dev/vda /runtime; "
          "for p in workspace tmp proc sys dev; do test -d /runtime/$p && test ! -L /runtime/$p; done; "
          "rm -rf /runtime/workspace; mkdir -m 700 /runtime/workspace; "
          "cp -a /tmp/rish-workspace/. /runtime/workspace/; "
          "mount -t proc proc /runtime/proc; mount --bind /sys /runtime/sys; "
          "mount --bind /dev /runtime/dev; mkdir -p /runtime/tmp/rish-home; "
          // Resolve the active guest hostname locally. Standard servers such
          // as Python HTTPServer query it before listening; that must not
          // depend on external DNS. Preserve other package-provided aliases.
          "if test -d /runtime/etc && test ! -L /runtime/etc; then "
          "rish_hostname=$(/bin/busybox hostname); "
          "rish_hosts=$(/bin/busybox mktemp /runtime/etc/.rish-hosts.XXXXXX); "
          "printf '127.0.0.1 localhost %s\\n::1 localhost %s\\n' \"$rish_hostname\" \"$rish_hostname\" > \"$rish_hosts\"; "
          "if test -f /runtime/etc/hosts && test ! -L /runtime/etc/hosts; then "
          "cat /runtime/etc/hosts >> \"$rish_hosts\"; fi; "
          "if test -L /runtime/etc/hosts; then rm -f /runtime/etc/hosts; fi; "
          "test ! -d /runtime/etc/hosts; chmod 644 \"$rish_hosts\"; "
          "mv -f \"$rish_hosts\" /runtime/etc/hosts; fi; "
          "if test -f /etc/resolv.conf && test -d /runtime/etc && test ! -L /runtime/etc; then "
          "rm -f /runtime/etc/resolv.conf; cp /etc/resolv.conf /runtime/etc/resolv.conf; fi";
      NSData *setupJSON = [NSJSONSerialization dataWithJSONObject:@{
        @"protocol_version":@2, @"command":@[@"/bin/sh", @"-c", setup],
        @"timeout_ms":@60000, @"max_output_bytes":@524288,
      } options:0 error:nil];
      NSDictionary *setupReply = setupJSON ? DecodeReply(rish_vm_session_exec_json(session,
          (const char *)setupJSON.bytes, setupJSON.length)) : nil;
      if (![setupReply[@"exit_code"] isKindOfClass:NSNumber.class] ||
          [setupReply[@"exit_code"] integerValue] != 0) { failure = @"E_PROGRAM_EXEC"; break; }
      NSError *operationError = nil;
      exitCode = operation(session, &operationError);
      if (operationError) failure = [operationError.domain isEqual:DSHRuntimeProgramErrorDomain]
          ? DSHRuntimeProgramError(operationError.userInfo[@"code"]).userInfo[@"code"] : @"E_PROGRAM_NATIVE";
    } while (NO);
  } @catch (__unused NSException *exception) {
    failure = @"E_PROGRAM_NATIVE";
  } @finally {
    if (session) rish_vm_session_free(session);
    if (owner) [DSHGuestRuntimeState.sharedState releaseGuestOwner:owner];
    if (overlay) [NSFileManager.defaultManager removeItemAtURL:overlay error:nil];
  }
  if (failure && error) *error = DSHRuntimeProgramError(failure);
  return exitCode;
}
- (NSNumber *)executeLease:(DSHRuntimeEnvironmentLease *)lease snapshot:(DSHRuntimeWorkspaceSnapshot *)snapshot
                 entryPath:(NSString *)entryPath args:(NSArray<NSString *> *)args
                   started:(dispatch_block_t)started output:(DSHRuntimeProgramOutput)output error:(NSError **)error {
  return [self performWithLease:lease snapshot:snapshot operation:^NSNumber *(void *session, NSError **inner) {
    NSArray *command = [DSHRuntimeProgramVM commandForManifest:lease.manifest entryPath:entryPath args:args];
    if (!command) { *inner = DSHRuntimeProgramError(@"E_PROGRAM_ENVIRONMENT"); return nil; }
    if (self.cancelled) return nil;
    started();
    NSData *request = [NSJSONSerialization dataWithJSONObject:@{
      @"protocol_version":@2, @"command":command, @"cwd":@"/",
      @"timeout_ms":@([DSHRuntimeProgramVM executionTimeoutMillisecondsForFamily:lease.manifest[@"family"]
          entryPath:entryPath]), @"max_output_bytes":@524288,
      @"env":@{@"HOME":@"/tmp/rish-home", @"PATH":@"/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
               @"TMPDIR":@"/tmp", @"GOCACHE":@"/tmp/go-build", @"CARGO_HOME":@"/tmp/cargo"},
    } options:0 error:nil];
    NSDictionary *reply = request ? DecodeReply(rish_vm_session_exec_stream_json(session,
        (const char *)request.bytes, request.length, (__bridge void *)output, OnOutput)) : nil;
    if ([reply[@"exit_code"] isKindOfClass:NSNumber.class]) return reply[@"exit_code"];
    NSString *internal = [reply[@"error"] isKindOfClass:NSString.class] ? reply[@"error"] : @"";
    *inner = DSHRuntimeProgramError([internal containsString:@"E_VM_TIMEOUT"] ? @"E_PROGRAM_TIMEOUT" :
        ([internal containsString:@"E_VM_OUTPUT_LIMIT"] ? @"E_PROGRAM_OUTPUT_LIMIT" : @"E_PROGRAM_EXEC"));
    return nil;
  } error:error];
}
@end
