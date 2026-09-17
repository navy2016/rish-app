#import "RuntimeEnvironmentPackage.h"
#import <CommonCrypto/CommonDigest.h>
#import <TargetConditionals.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>
#include <zlib.h>
#include <math.h>
#include "rish_agent_core.h"

NSString *const DSHRuntimeEnvironmentErrorDomain = @"DSHRuntimeEnvironmentError";
static uint64_t const MaxPackageBytes = 768ULL * 1024 * 1024;

NSError *DSHEnvironmentError(NSString *code) {
  return [NSError errorWithDomain:DSHRuntimeEnvironmentErrorDomain code:1
                        userInfo:@{@"code":code, NSLocalizedDescriptionKey:code}];
}

// What an environment identity, a download URL and a package manifest have to
// be lives in the shared core (modules/rish/core,
// `rish_agent_runtime_environment_reduce`). Everything below this block is
// still the host's: directories, capacity, file protection, hashing, and
// streaming one package into a disk.
static BOOL DSHEnvironmentReduceValid(NSString *op, NSDictionary *fields) {
  NSMutableDictionary *envelope = [fields mutableCopy];
  envelope[@"op"] = op;
  // A value that cannot be JSON is not a valid anything, and saying so here
  // keeps a refusal from turning into a crash inside NSJSONSerialization.
  if (![NSJSONSerialization isValidJSONObject:envelope]) return NO;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:nil];
  char *raw = bytes == nil ? NULL : rish_agent_runtime_environment_reduce(
      (const char *)bytes.bytes, bytes.length);
  if (raw == NULL) return NO;
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0 error:nil];
  if (![reply isKindOfClass:NSDictionary.class]) return NO;
  return [reply[@"ok"] isEqual:@YES] && [reply[@"valid"] isEqual:@YES];
}

// `value` is `id`, so nil has to become a JSON null rather than truncate the
// dictionary literal and change which key the core is asked about.
static id DSHEnvironmentJSONValue(id value) {
  return value == nil ? NSNull.null : value;
}

BOOL DSHEnvironmentValidId(id value) {
  return DSHEnvironmentReduceValid(@"valid_environment_id",
                                   @{@"value": DSHEnvironmentJSONValue(value)});
}

BOOL DSHEnvironmentValidWorkspaceId(id value) {
  return DSHEnvironmentReduceValid(@"valid_workspace_id",
                                   @{@"value": DSHEnvironmentJSONValue(value)});
}

BOOL DSHEnvironmentValidHTTPSURL(id value) {
  // NSURLComponents decides what counts as a host or a fragment here, and the
  // core decides what those parts have to be. Projecting rather than moving
  // the parse keeps the set of accepted downloads exactly where it was.
  if (![value isKindOfClass:NSString.class]) {
    return DSHEnvironmentReduceValid(@"valid_https_url",
                                     @{@"value": DSHEnvironmentJSONValue(value)});
  }
  NSURLComponents *parts = [NSURLComponents componentsWithString:value];
  NSDictionary *projection = @{
    @"text": value,
    @"parsed": parts == nil ? @NO : @YES,
    @"scheme": parts.scheme ?: NSNull.null,
    @"host": parts.host ?: NSNull.null,
    @"has_user": parts.user == nil ? @NO : @YES,
    @"has_password": parts.password == nil ? @NO : @YES,
    @"has_fragment": parts.fragment == nil ? @NO : @YES,
  };
  return DSHEnvironmentReduceValid(@"valid_https_url", @{@"value": projection});
}

BOOL DSHEnvironmentValidateManifest(id value, NSString *kernelSHA256) {
  if (kernelSHA256 == nil) return NO;
  return DSHEnvironmentReduceValid(@"validate_manifest", @{
    @"value": DSHEnvironmentJSONValue(value),
    @"kernel_sha256": kernelSHA256,
  });
}

BOOL DSHEnvironmentEnsureDirectory(NSURL *url) {
  struct stat s = {};
  if (lstat(url.fileSystemRepresentation, &s) != 0) {
    if (errno != ENOENT || mkdir(url.fileSystemRepresentation, 0700) != 0) return NO;
  } else if (!S_ISDIR(s.st_mode) || S_ISLNK(s.st_mode)) return NO;
  return chmod(url.fileSystemRepresentation, 0700) == 0
      && [NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication}
          ofItemAtPath:url.path error:nil]
      && [url setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
}
BOOL DSHEnvironmentHasCapacity(NSURL *url, uint64_t requiredBytes) {
  struct statvfs info = {};
  if (statvfs(url.fileSystemRepresentation, &info) != 0) return NO;
  return (uint64_t)info.f_bavail * info.f_frsize >= requiredBytes + 256ULL * 1024 * 1024;
}
BOOL DSHEnvironmentProtectFile(NSURL *url) {
  NSFileManager *files = NSFileManager.defaultManager;
  if (![files setAttributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication}
      ofItemAtPath:url.path error:nil]) return NO;
  NSDictionary *attributes = [files attributesOfItemAtPath:url.path error:nil];
#if TARGET_OS_SIMULATOR || TARGET_OS_OSX
  // Simulator/macOS do not implement device Data Protection. Real-device builds require the readback below.
  return attributes != nil;
#else
  return [attributes[NSFileProtectionKey] isEqual:NSFileProtectionCompleteUntilFirstUserAuthentication];
#endif
}
NSData *DSHEnvironmentReadSmallFile(NSURL *url, NSUInteger limit) {
  int fd = open(url.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  struct stat s = {};
  if (fd < 0) return nil;
  if (fstat(fd, &s) != 0 || !S_ISREG(s.st_mode) || s.st_size < 1 || (uint64_t)s.st_size > limit) {
    close(fd); return nil;
  }
  NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)s.st_size];
  size_t done = 0;
  while (done < data.length) {
    ssize_t n = read(fd, (uint8_t *)data.mutableBytes + done, data.length - done);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) { close(fd); return nil; }
    done += n;
  }
  close(fd); return data;
}
static NSString *DigestHex(unsigned char *digest) {
  NSMutableString *hex = [NSMutableString stringWithCapacity:64];
  for (NSUInteger n = 0; n < CC_SHA256_DIGEST_LENGTH; n++) [hex appendFormat:@"%02x", digest[n]];
  return hex;
}
static NSString *HashFD(int fd, uint64_t limit, BOOL (^cancelled)(void)) {
  CC_SHA256_CTX hash; CC_SHA256_Init(&hash);
  uint8_t buffer[65536]; uint64_t total = 0;
  while (YES) {
    if (cancelled && cancelled()) return nil;
    ssize_t n = read(fd, buffer, sizeof(buffer));
    if (n < 0 && errno == EINTR) continue;
    if (n < 0) return nil;
    if (n == 0) break;
    total += n; if (total > limit) return nil;
    CC_SHA256_Update(&hash, buffer, (CC_LONG)n);
  }
  unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest, &hash);
  return DigestHex(digest);
}
NSString *DSHEnvironmentHashFile(NSURL *url, uint64_t limit, BOOL (^cancelled)(void)) {
  int fd = open(url.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) return nil;
  struct stat s = {};
  NSString *digest = nil;
  if (fstat(fd, &s) == 0 && S_ISREG(s.st_mode) && s.st_size >= 0 && (uint64_t)s.st_size <= limit)
    digest = HashFD(fd, limit, cancelled);
  close(fd); return digest;
}
static BOOL ReadExact(int fd, void *bytes, size_t count) {
  size_t done = 0;
  while (done < count) {
    ssize_t n = read(fd, (uint8_t *)bytes + done, count - done);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return NO;
    done += n;
  }
  return YES;
}
static BOOL WriteExact(int fd, const void *bytes, size_t count) {
  size_t done = 0;
  while (done < count) {
    ssize_t n = write(fd, (const uint8_t *)bytes + done, count - done);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return NO;
    done += n;
  }
  return YES;
}

@implementation DSHRuntimeEnvironmentPackage
+ (NSDictionary *)unpackURL:(NSURL *)packageURL diskURL:(NSURL *)diskURL kernelSHA256:(NSString *)kernelSHA256
             expectedRecord:(NSDictionary *)record cancelled:(BOOL (^)(void))cancelled error:(NSError **)error {
  NSString *failure = @"E_ENV_PACKAGE_INVALID";
  int input = open(packageURL.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  int output = -1; BOOL created = NO; NSDictionary *manifest = nil;
  z_stream stream = {}; BOOL initialized = NO; BOOL success = NO;
  do {
    struct stat metadata = {};
    if (input < 0 || fstat(input, &metadata) != 0 || !S_ISREG(metadata.st_mode)
        || metadata.st_size < 13 || (uint64_t)metadata.st_size > MaxPackageBytes) break;
    if (record) {
      if ((uint64_t)metadata.st_size != [record[@"package_bytes"] unsignedLongLongValue]
          || ![HashFD(input, MaxPackageBytes, cancelled) isEqual:record[@"package_sha256"]]) {
        failure = @"E_ENV_INTEGRITY"; break;
      }
      if (lseek(input, 0, SEEK_SET) != 0) break;
    }
    uint8_t prefix[12];
    if (!ReadExact(input, prefix, sizeof(prefix)) || memcmp(prefix, "RISHENV1", 8) != 0) break;
    uint32_t size = ((uint32_t)prefix[8] << 24) | ((uint32_t)prefix[9] << 16) | ((uint32_t)prefix[10] << 8) | prefix[11];
    if (size < 1 || size > 16384) break;
    NSMutableData *header = [NSMutableData dataWithLength:size];
    if (!ReadExact(input, header.mutableBytes, size)) break;
    manifest = [NSJSONSerialization JSONObjectWithData:header options:0 error:nil];
    if (!DSHEnvironmentValidateManifest(manifest, kernelSHA256)) { failure = @"E_ENV_INCOMPATIBLE"; break; }
    if (record && ![manifest isEqual:record[@"manifest"]]) { failure = @"E_ENV_INTEGRITY"; break; }
    uint64_t expected = [manifest[@"disk_bytes"] unsignedLongLongValue];
    if (!DSHEnvironmentHasCapacity(diskURL.URLByDeletingLastPathComponent, expected)) { failure = @"E_ENV_DISK_SPACE"; break; }
    output = open(diskURL.fileSystemRepresentation, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (output < 0) { failure = @"E_ENV_STORAGE"; break; }
    created = YES;
    if (inflateInit2(&stream, 15 + 16) != Z_OK) break;
    initialized = YES;
    CC_SHA256_CTX hash; CC_SHA256_Init(&hash);
    uint8_t in[65536], out[65536], superblock[2048] = {}; uint64_t total = 0;
    int result = Z_OK; BOOL streamOK = YES;
    while (result != Z_STREAM_END) {
      if (cancelled()) { failure = @"E_ENV_CANCELLED"; streamOK = NO; break; }
      if (stream.avail_in == 0) {
        ssize_t count = read(input, in, sizeof(in));
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { streamOK = NO; break; }
        stream.next_in = in; stream.avail_in = (uInt)count;
      }
      stream.next_out = out; stream.avail_out = sizeof(out);
      result = inflate(&stream, Z_NO_FLUSH);
      if (result != Z_OK && result != Z_STREAM_END) { streamOK = NO; break; }
      size_t count = sizeof(out) - stream.avail_out;
      if (total + count > expected) { streamOK = NO; break; }
      if (total < sizeof(superblock)) memcpy(superblock + total, out, MIN(count, sizeof(superblock) - total));
      if (!WriteExact(output, out, count)) { failure = @"E_ENV_STORAGE"; streamOK = NO; break; }
      CC_SHA256_Update(&hash, out, (CC_LONG)count); total += count;
    }
    uint8_t trailing;
    if (!streamOK || result != Z_STREAM_END || stream.avail_in != 0 || read(input, &trailing, 1) != 0
        || total != expected) break;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest, &hash);
    if (![DigestHex(digest) isEqual:manifest[@"disk_sha256"]]) { failure = @"E_ENV_INTEGRITY"; break; }
    // ext4 superblock magic plus bounded filesystem geometry. The filesystem is never mounted on the host.
    uint32_t blocks = (uint32_t)superblock[1028] | ((uint32_t)superblock[1029] << 8)
        | ((uint32_t)superblock[1030] << 16) | ((uint32_t)superblock[1031] << 24);
    uint32_t shift = (uint32_t)superblock[1048] | ((uint32_t)superblock[1049] << 8)
        | ((uint32_t)superblock[1050] << 16) | ((uint32_t)superblock[1051] << 24);
    if (superblock[1080] != 0x53 || superblock[1081] != 0xef || shift > 6 || blocks == 0
        || (uint64_t)blocks * (1024ULL << shift) > expected) break;
    if (cancelled()) { failure = @"E_ENV_CANCELLED"; break; }
    if (!DSHEnvironmentProtectFile(diskURL) || fsync(output) != 0 || fchmod(output, 0400) != 0) {
      failure = @"E_ENV_STORAGE"; break;
    }
    success = YES;
  } while (NO);
  if (initialized) inflateEnd(&stream);
  if (input >= 0) close(input);
  if (output >= 0) close(output);
  if (!success) {
    if (created) unlink(diskURL.fileSystemRepresentation);
    if (error) *error = DSHEnvironmentError(cancelled() ? @"E_ENV_CANCELLED" : failure);
    return nil;
  }
  return manifest;
}
@end
