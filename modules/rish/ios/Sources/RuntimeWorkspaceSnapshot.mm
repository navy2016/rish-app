#import "RuntimeWorkspaceSnapshot.h"
#import "AgentNativeWAL.h"
#import "AgentRootResolver.h"
#import "SessionWorkspaceCoordinator.h"
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include "rish_agent_core.h"

NSErrorDomain const DSHRuntimeProgramErrorDomain = @"tech.zseven.rish.program";

NSError *DSHRuntimeProgramError(NSString *code) {
  static NSSet *codes;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ codes = [NSSet setWithArray:@[
    @"E_PROGRAM_INVALID_REQUEST", @"E_PROGRAM_BUSY", @"E_PROGRAM_NOT_FOUND",
    @"E_PROGRAM_OPERATION_CONFLICT", @"E_PROGRAM_ROOT_STALE", @"E_PROGRAM_SNAPSHOT_LIMIT",
    @"E_PROGRAM_UNSAFE_PATH", @"E_PROGRAM_STORAGE", @"E_PROGRAM_ENVIRONMENT",
    @"E_PROGRAM_ASSETS_MISSING", @"E_PROGRAM_ASSET_INTEGRITY", @"E_PROGRAM_UNAVAILABLE",
    @"E_PROGRAM_BOOT", @"E_PROGRAM_EXEC", @"E_PROGRAM_NATIVE",
    @"E_PROGRAM_TIMEOUT", @"E_PROGRAM_OUTPUT_LIMIT",
  ]]; });
  if (![codes containsObject:code]) code = @"E_PROGRAM_NATIVE";
  return [NSError errorWithDomain:DSHRuntimeProgramErrorDomain code:1 userInfo:@{
    @"code": code, NSLocalizedDescriptionKey: code,
  }];
}

BOOL DSHRuntimeProgramValidRoot(id root) {
  return DSHAgentExactDictionaryKeys(root,
      @[@"schema_version", @"workspace_id", @"binding_revision", @"project_id"]) &&
    DSHAgentSafeInteger(root[@"schema_version"], 1, NO) &&
    DSHAgentCanonicalUUID(root[@"workspace_id"]) &&
    DSHAgentSafeInteger(root[@"binding_revision"], 9007199254740991ULL, NO) &&
    (root[@"project_id"] == NSNull.null || DSHAgentCanonicalUUID(root[@"project_id"]));
}

BOOL DSHRuntimeProgramValidEnvironmentId(id value) {
  NSDictionary *envelope = @{
    @"op": @"valid_program_environment_id",
    @"value": value == nil ? NSNull.null : value,
  };
  if (![NSJSONSerialization isValidJSONObject:envelope]) return NO;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:nil];
  char *raw = bytes == nil ? NULL : rish_agent_runtime_environment_reduce(
      (const char *)bytes.bytes, bytes.length);
  if (raw == NULL) return NO;
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0 error:nil];
  return [reply isKindOfClass:NSDictionary.class] && [reply[@"ok"] isEqual:@YES]
      && [reply[@"valid"] isEqual:@YES];
}

BOOL DSHRuntimeProgramValidPath(id value) {
  if (![value isKindOfClass:NSString.class]) return NO;
  NSString *path = value;
  NSData *encoded = [path dataUsingEncoding:NSUTF8StringEncoding];
  if (encoded == nil || encoded.length == 0 || encoded.length > 1024 ||
      [path hasPrefix:@"/"] || [path containsString:@"\0"] || [path containsString:@"\\"]) return NO;
  NSArray *parts = [path componentsSeparatedByString:@"/"];
  if (parts.count > 32) return NO;
  for (NSString *part in parts) {
    if (part.length == 0 || [part isEqual:@"."] || [part isEqual:@".."] ||
        [part lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 255) return NO;
  }
  return YES;
}

static BOOL SameIdentity(const struct stat &a, const struct stat &b) {
  return a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode &&
      a.st_size == b.st_size && a.st_nlink == b.st_nlink &&
      a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec &&
      a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
      a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec &&
      a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec;
}

static BOOL Fail(NSError **error, NSString *code) {
  if (error) *error = DSHRuntimeProgramError(code);
  return NO;
}

static BOOL IgnoredDirectory(NSString *name) {
  return [@[@".git", @".trash", @".cache", @"staging", @"cache", @"node_modules",
            @"target", @".rish-staging", @".gradle", @"__pycache__"] containsObject:name];
}

/// Every component is opened relative to a leased descriptor. Identity checks
/// reject replacement and mutation while copying, including directory changes.
static BOOL Walk(int directory, NSString *prefix, NSMutableArray *entries,
                 NSUInteger *total, NSUInteger *files, NSUInteger *nodes,
                 NSError **error) {
  struct stat before, after;
  if (fstat(directory, &before) || !S_ISDIR(before.st_mode))
    return Fail(error, @"E_PROGRAM_UNSAFE_PATH");
  int duplicate = dup(directory);
  DIR *stream = duplicate < 0 ? NULL : fdopendir(duplicate);
  if (stream == NULL) {
    if (duplicate >= 0) close(duplicate);
    return Fail(error, @"E_PROGRAM_STORAGE");
  }
  NSMutableArray<NSString *> *names = [NSMutableArray array];
  errno = 0;
  struct dirent *item;
  BOOL okay = YES;
  while ((item = readdir(stream)) != NULL) {
    if (!strcmp(item->d_name, ".") || !strcmp(item->d_name, "..")) continue;
    if (++(*nodes) > 1024) { okay = Fail(error, @"E_PROGRAM_SNAPSHOT_LIMIT"); break; }
    NSString *name = [[NSString alloc] initWithBytes:item->d_name
        length:strlen(item->d_name) encoding:NSUTF8StringEncoding];
    if (name == nil) { okay = Fail(error, @"E_PROGRAM_UNSAFE_PATH"); break; }
    [names addObject:name];
  }
  if (errno != 0 && okay) okay = Fail(error, @"E_PROGRAM_STORAGE");
  closedir(stream);
  if (!okay) return NO;
  [names sortUsingSelector:@selector(compare:)];
  for (NSString *name in names) {
    NSString *path = prefix.length ? [prefix stringByAppendingFormat:@"/%@", name] : name;
    if (!DSHRuntimeProgramValidPath(path)) return Fail(error, @"E_PROGRAM_UNSAFE_PATH");
    struct stat listed, opened, finished, finalName;
    if (fstatat(directory, name.fileSystemRepresentation, &listed, AT_SYMLINK_NOFOLLOW))
      return Fail(error, @"E_PROGRAM_ROOT_STALE");
    if (S_ISDIR(listed.st_mode) && IgnoredDirectory(name)) continue;
    if (!S_ISDIR(listed.st_mode) && !S_ISREG(listed.st_mode))
      return Fail(error, @"E_PROGRAM_UNSAFE_PATH");
    int descriptor = openat(directory, name.fileSystemRepresentation,
        O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (S_ISDIR(listed.st_mode) ? O_DIRECTORY : 0));
    if (descriptor < 0 || fstat(descriptor, &opened) || !SameIdentity(listed, opened)) {
      if (descriptor >= 0) close(descriptor);
      return Fail(error, @"E_PROGRAM_ROOT_STALE");
    }
    if (S_ISDIR(opened.st_mode)) {
      [entries addObject:@{@"path":path, @"directory":@YES, @"data":NSData.data, @"mode":@0755}];
      okay = Walk(descriptor, path, entries, total, files, nodes, error);
    } else {
      if (opened.st_nlink != 1) okay = Fail(error, @"E_PROGRAM_UNSAFE_PATH");
      else if (++(*files) > 256 || opened.st_size < 0 || opened.st_size > 2 * 1024 * 1024 ||
          (NSUInteger)opened.st_size > 16 * 1024 * 1024 - *total)
        okay = Fail(error, @"E_PROGRAM_SNAPSHOT_LIMIT");
      else {
        NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)opened.st_size];
        NSUInteger offset = 0;
        while (okay && offset < data.length) {
          ssize_t count = read(descriptor, (uint8_t *)data.mutableBytes + offset, data.length - offset);
          if (count < 0 && errno == EINTR) continue;
          if (count <= 0) { okay = Fail(error, @"E_PROGRAM_ROOT_STALE"); break; }
          offset += (NSUInteger)count;
        }
        if (okay) {
          *total += data.length;
          [entries addObject:@{@"path":path, @"directory":@NO, @"data":[data copy],
              @"mode":@((opened.st_mode & 0111) ? 0755 : 0644)}];
        }
      }
    }
    if (okay && (fstat(descriptor, &finished) || !SameIdentity(opened, finished) ||
        fstatat(directory, name.fileSystemRepresentation, &finalName, AT_SYMLINK_NOFOLLOW) ||
        !SameIdentity(opened, finalName))) okay = Fail(error, @"E_PROGRAM_ROOT_STALE");
    close(descriptor);
    if (!okay) return NO;
  }
  if (fstat(directory, &after) || !SameIdentity(before, after))
    return Fail(error, @"E_PROGRAM_ROOT_STALE");
  return YES;
}

@interface DSHRuntimeWorkspaceSnapshot ()
@property(nonatomic, copy, readwrite) NSDictionary *frozenRoot;
@property(nonatomic, copy, readwrite) NSArray<NSDictionary *> *entries;
@property(nonatomic, readwrite) NSUInteger totalBytes;
@end

@implementation DSHRuntimeWorkspaceSnapshot
+ (instancetype)captureRoot:(NSDictionary *)rootRef entryPath:(NSString *)entryPath
                    resolver:(DSHAgentRootResolver *)resolver error:(NSError **)error {
  if (!DSHRuntimeProgramValidRoot(rootRef) || !DSHRuntimeProgramValidPath(entryPath)) {
    Fail(error, @"E_PROGRAM_INVALID_REQUEST"); return nil;
  }
  __block DSHRuntimeWorkspaceSnapshot *result = nil;
  NSError *failure = nil;
  BOOL completed = DSHPerformSessionWorkspaceTransaction(^BOOL(NSError **inner) {
    NSDictionary *root = [resolver resolveRootForWorkspaceId:rootRef[@"workspace_id"]
        projectId:rootRef[@"project_id"] == NSNull.null ? nil : rootRef[@"project_id"]
        bindingRevision:rootRef[@"binding_revision"] error:nil];
    if (![DSHAgentRootResolver validateAgentRootProjection:root error:nil] ||
        ![root[@"workspace_id"] isEqual:rootRef[@"workspace_id"]] ||
        ![root[@"workspace_binding_revision"] isEqual:rootRef[@"binding_revision"]] ||
        ![root[@"project_id"] isEqual:rootRef[@"project_id"]])
      return Fail(inner, @"E_PROGRAM_ROOT_STALE");
    NSMutableArray *entries = [NSMutableArray array];
    __block NSUInteger total = 0, files = 0, nodes = 0;
    NSError *readError = nil;
    BOOL read = [resolver performOperationForFrozenRoot:root mode:DSHAgentRootOperationModeRead
        timeout:5 block:^BOOL(int fd, git_repository *repo, NSError **copyError) {
      (void)repo;
      return Walk(fd, @"", entries, &total, &files, &nodes, copyError);
    } error:&readError];
    if (!read) {
      *inner = [readError.domain isEqual:DSHRuntimeProgramErrorDomain]
          ? readError : DSHRuntimeProgramError(@"E_PROGRAM_ROOT_STALE");
      return NO;
    }
    BOOL found = NO;
    for (NSDictionary *entry in entries) {
      if ([entry[@"path"] isEqual:entryPath] && ![entry[@"directory"] boolValue]) found = YES;
    }
    if (!found) return Fail(inner, @"E_PROGRAM_NOT_FOUND");
    if (![resolver validateFrozenRoot:root error:nil]) return Fail(inner, @"E_PROGRAM_ROOT_STALE");
    result = [[self alloc] init];
    result.frozenRoot = root; result.entries = entries; result.totalBytes = total;
    return YES;
  }, &failure);
  if (!completed) {
    if (error) *error = [failure.domain isEqual:DSHRuntimeProgramErrorDomain]
        ? failure : DSHRuntimeProgramError(@"E_PROGRAM_NATIVE");
    return nil;
  }
  return result;
}
@end
