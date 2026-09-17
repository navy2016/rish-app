#import "LocalProjectAccess.h"
#import "LocalProjectAccessInternals.h"

#import "DSHWorkspaceCanonical.h"

#include "rish_agent_core.h"
#import "LocalWorkspaceAccess.h"

#import <CommonCrypto/CommonDigest.h>

#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

#include <chrono>
#include <shared_mutex>

// The workspace resolver intentionally keeps authority records private. This
// narrow native-only category lets the project lease bind its private root
// fingerprint without adding any bridge-visible accessor or duplicating the
// registry parser.
@interface DSHLocalWorkspaceAccess (DSHLocalProjectAuthorityAccess)
@property(nonatomic, strong) NSURL *privateRootURL;
- (nullable NSURL *)ownedWorkspacesRootURL;
- (nullable NSDictionary *)loadRegistry:(NSError **)error
                                  digest:(NSString *_Nullable *_Nullable)digest;
- (nullable NSDictionary *)recordInRegistry:(NSDictionary *)registry
                                  workspaceId:(NSString *)workspaceId;
- (nullable NSDictionary *)loadAuthorityForRecord:(NSDictionary *)record
                                             error:(NSError **)error;
@end

NSErrorDomain const DSHLocalProjectAccessErrorDomain =
    @"dev.zseven.rish.local-project-access";

static const NSUInteger DSHProjectMetadataMaxBytes = 64 * 1024;

static NSError *DSHAccessError(DSHLocalProjectAccessErrorCode code) {
  NSString *message = @"Project storage is unavailable.";
  switch (code) {
    case DSHLocalProjectAccessErrorInvalidIdentifier:
      message = @"Project identifier is invalid.";
      break;
    case DSHLocalProjectAccessErrorUnsafeStorage:
      message = @"Project storage is unsafe.";
      break;
    case DSHLocalProjectAccessErrorRepositoryUnavailable:
      message = @"Repository cannot be opened.";
      break;
    case DSHLocalProjectAccessErrorMetadataInvalid:
      message = @"Project metadata is invalid.";
      break;
    case DSHLocalProjectAccessErrorLockTimeout:
      message = @"Project access timed out.";
      break;
    case DSHLocalProjectAccessErrorRootAbsent:
    case DSHLocalProjectAccessErrorStorageUnavailable:
      break;
  }
  return [NSError errorWithDomain:DSHLocalProjectAccessErrorDomain
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey : message}];
}

static void DSHSetAccessError(NSError **error,
                              DSHLocalProjectAccessErrorCode code) {
  if (error != nil) *error = DSHAccessError(code);
}

static BOOL DSHHasControlCharacter(NSString *value) {
  return [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet]
             .location != NSNotFound;
}

static BOOL DSHDictionaryHasExactKeys(NSDictionary *object,
                                      NSArray<NSString *> *keys) {
  if (![object isKindOfClass:NSDictionary.class] || object.count != keys.count) {
    return NO;
  }
  NSSet *allowed = [NSSet setWithArray:keys];
  for (id key in object) {
    if (![key isKindOfClass:NSString.class] || ![allowed containsObject:key]) {
      return NO;
    }
  }
  return YES;
}

static BOOL DSHLocalProjectIsBoolean(id value) {
  return [value isKindOfClass:NSNumber.class] &&
         CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL DSHLocalProjectSafeRevision(id value, NSUInteger *revisionOut) {
  if (![value isKindOfClass:NSNumber.class] ||
      DSHLocalProjectIsBoolean(value) || [value isKindOfClass:NSDecimalNumber.class]) {
    return NO;
  }
  NSNumber *number = value;
  double decimal = number.doubleValue;
  if (!isfinite(decimal) || signbit(decimal) || floor(decimal) != decimal ||
      decimal < 1.0 || decimal > 9007199254740991.0 ||
      number.unsignedLongLongValue != (unsigned long long)decimal) {
    return NO;
  }
  if (revisionOut != nullptr) *revisionOut = (NSUInteger)decimal;
  return YES;
}

static BOOL DSHLocalProjectCanonicalDigest(id value) {
  if (![value isKindOfClass:NSString.class] || [value length] != 64) {
    return NO;
  }
  NSCharacterSet *hex =
      [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
  return [value rangeOfCharacterFromSet:hex.invertedSet].location == NSNotFound;
}

// What a project binding, its root reference and its stored metadata look
// like lives in the shared core (modules/rish/core,
// `rish_agent_project_access_reduce`). The git directory crosses as a path and
// a flag rather than an NSURL, and Foundation's trimming crosses as the
// trimmed spelling.
static NSDictionary *DSHLocalProjectReduce(NSString *op, NSDictionary *fields) {
  NSMutableDictionary *envelope = [fields mutableCopy];
  envelope[@"op"] = op;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:envelope options:0
                                                    error:nil];
  char *raw = bytes == nil ? NULL : rish_agent_project_access_reduce(
      (const char *)bytes.bytes, bytes.length);
  if (raw == NULL) return nil;
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0
                                                error:nil];
  return [reply isKindOfClass:NSDictionary.class] &&
      [reply[@"ok"] isEqual:@YES] ? reply : nil;
}

/// A binding as JSON: the git directory URL is not a JSON value, so it becomes
/// its path alongside a flag saying whether it was a file URL at all.
static NSDictionary *DSHLocalProjectBindingFields(NSDictionary *binding) {
  if (![binding isKindOfClass:NSDictionary.class]) return nil;
  NSMutableDictionary *fields = [binding mutableCopy];
  id url = binding[@"git_directory_url"];
  fields[@"git_directory_url"] =
      [url isKindOfClass:NSURL.class] ? [url absoluteString] : NSNull.null;
  return fields;
}

static BOOL DSHLocalProjectBindingIsValid(NSDictionary *binding,
                                          NSDictionary *rootRef,
                                          NSString *rootFingerprint) {
  id url = [binding isKindOfClass:NSDictionary.class]
      ? binding[@"git_directory_url"] : nil;
  BOOL isFileURL = [url isKindOfClass:NSURL.class] && [url isFileURL];
  NSString *path = [url isKindOfClass:NSURL.class] ? [url path] : nil;
  return [DSHLocalProjectReduce(@"binding_valid", @{
    @"binding" : DSHLocalProjectBindingFields(binding) ?: NSNull.null,
    @"root_ref" : [rootRef isKindOfClass:NSDictionary.class] ? rootRef
                                                             : NSNull.null,
    @"root_fingerprint_sha256" : rootFingerprint ?: NSNull.null,
    @"git_is_file_url" : isFileURL ? @YES : @NO,
    @"git_directory_path" : path ?: NSNull.null,
  })[@"valid"] isEqual:@YES];
}

static NSString *DSHLocalProjectBindingDigest(NSDictionary *binding) {
  id digest = DSHLocalProjectReduce(@"binding_digest", @{
    @"binding" : DSHLocalProjectBindingFields(binding) ?: NSNull.null,
  })[@"digest"];
  return [digest isKindOfClass:NSString.class] ? digest : nil;
}

static BOOL DSHLocalProjectRootRefIsValid(NSDictionary *rootRef,
                                          BOOL projectRequired,
                                          NSUInteger *revisionOut) {
  if (![DSHLocalProjectReduce(@"root_ref_valid", @{
        @"root_ref" : [rootRef isKindOfClass:NSDictionary.class] ? rootRef
                                                                 : NSNull.null,
        @"project_required" : projectRequired ? @YES : @NO,
      })[@"valid"] isEqual:@YES]) {
    return NO;
  }
  // The revision is handed back to the caller as a number it can hold; the
  // rule has already said it is one.
  if (revisionOut != nullptr) {
    *revisionOut = [rootRef[@"binding_revision"] unsignedIntegerValue];
  }
  return YES;
}

static NSDictionary *DSHLocalProjectCanonicalRootRef(NSDictionary *rootRef) {
  id canonical = DSHLocalProjectReduce(@"canonical_root_ref", @{
    @"root_ref" : [rootRef isKindOfClass:NSDictionary.class] ? rootRef
                                                             : NSNull.null,
  })[@"root_ref"];
  return [canonical isKindOfClass:NSDictionary.class] ? canonical : nil;
}

static BOOL DSHSameNode(const struct stat &left, const struct stat &right);
static NSString *DSHFileSystemString(const char *path);

// Canonicalizes the trusted system symlink aliases (/var -> /private/var,
// /tmp -> /private/tmp, /etc -> /private/etc) so paths can be compared
// against the canonical container root.
static NSString *DSHApplyTrustedSystemAliases(NSString *path) {
  NSDictionary<NSString *, NSString *> *trustedSystemAliases = @{
    @"/var" : @"/private/var",
    @"/tmp" : @"/private/tmp",
    @"/etc" : @"/private/etc",
  };
  for (NSString *alias in trustedSystemAliases) {
    if ([path isEqual:alias] ||
        [path hasPrefix:[alias stringByAppendingString:@"/"]]) {
      return [trustedSystemAliases[alias]
          stringByAppendingString:[path substringFromIndex:alias.length]];
    }
  }
  return path;
}

// Where a path stops being the app's own container lives in the shared core
// (modules/rish/core, `rish_agent_container_anchor_reduce`). Splitting a path
// into components stays here: `pathComponents` is Foundation's, and it keeps a
// leading "/" that a naive split would not.
static NSArray<NSString *> *DSHContainerAnchorComponents(NSString *path) {
  return [path isKindOfClass:NSString.class] ? path.pathComponents : nil;
}

NSUInteger DSHContainerAnchorSegmentCountForPaths(NSString *targetPath,
                                                  NSString *containerRootPath) {
  NSArray<NSString *> *target = DSHContainerAnchorComponents(targetPath);
  NSArray<NSString *> *root = DSHContainerAnchorComponents(containerRootPath);
  if (target == nil || root == nil) return NSNotFound;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:@{
    @"op" : @"anchor_segment_count",
    @"target" : target,
    @"container_root" : root,
  } options:0 error:nil];
  char *raw = bytes == nil ? NULL : rish_agent_container_anchor_reduce(
      (const char *)bytes.bytes, bytes.length);
  if (raw == NULL) return NSNotFound;
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0
                                                error:nil];
  if (![reply isKindOfClass:NSDictionary.class] ||
      ![reply[@"ok"] isEqual:@YES]) {
    return NSNotFound;
  }
  id segments = reply[@"segments"];
  return [segments isKindOfClass:NSNumber.class]
      ? [segments unsignedIntegerValue]
      : NSNotFound;
}

// One component list in, one index out. `op` and `key` name which of the two
// index-shaped answers is wanted.
static NSUInteger DSHContainerAnchorIndex(NSString *op, NSString *key,
                                          NSArray<NSString *> *components) {
  if (components == nil) return NSNotFound;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:@{
    @"op" : op,
    [op isEqual:@"scan_segment_count"] ? @"target" : @"components" : components,
  } options:0 error:nil];
  char *raw = bytes == nil ? NULL : rish_agent_container_anchor_reduce(
      (const char *)bytes.bytes, bytes.length);
  if (raw == NULL) return NSNotFound;
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0
                                                error:nil];
  if (![reply isKindOfClass:NSDictionary.class] ||
      ![reply[@"ok"] isEqual:@YES]) {
    return NSNotFound;
  }
  id index = reply[key];
  return [index isKindOfClass:NSNumber.class] ? [index unsignedIntegerValue]
                                              : NSNotFound;
}

NSUInteger DSHContainerRootScanSegmentCount(NSString *path) {
  if (![path isKindOfClass:NSString.class]) return NSNotFound;
  // The same rule without a root to check against.
  return DSHContainerAnchorIndex(@"scan_segment_count", @"segments",
                                 path.pathComponents);
}

BOOL DSHLocalProjectAccessValidateWorkspaceRootRefV1(
    NSDictionary *rootRef,
    BOOL projectRequired,
    NSError **error) {
  if (!DSHLocalProjectRootRefIsValid(rootRef, projectRequired, nullptr)) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorInvalidIdentifier);
    return NO;
  }
  return YES;
}

BOOL DSHLocalProjectAccessParseCanonicalUInt64(
    id value,
    unsigned long long *valueOut) {
  NSString *decimal = nil;
  if ([value isKindOfClass:NSString.class]) {
    decimal = value;
  } else if ([value isKindOfClass:NSNumber.class] &&
             !DSHLocalProjectIsBoolean(value) &&
             ![value isKindOfClass:NSDecimalNumber.class]) {
    // NSNumber's stringValue preserves the exact integer spelling for the
    // integral values emitted by legacy/native records. Fractional NSNumber
    // values retain a decimal point and are rejected by the same parser.
    decimal = [value stringValue];
  } else {
    return NO;
  }
  if (decimal.length == 0 || decimal.length > 20 ||
      (decimal.length > 1 && [decimal hasPrefix:@"0"])) {
    return NO;
  }
  unsigned long long parsed = 0;
  for (NSUInteger index = 0; index < decimal.length; index++) {
    unichar character = [decimal characterAtIndex:index];
    if (character < '0' || character > '9') return NO;
    unsigned long long digit = (unsigned long long)(character - '0');
    if (parsed > (ULLONG_MAX - digit) / 10ULL) return NO;
    parsed = parsed * 10ULL + digit;
  }
  if (valueOut != nullptr) *valueOut = parsed;
  return YES;
}

static int DSHOpenAnchoredAbsoluteDirectory(
    NSURL *url, DSHLocalProjectAccessHook hook, NSError **error) {
  if (![url isFileURL] || ![url.path hasPrefix:@"/"]) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return -1;
  }
  NSString *physicalPath = url.path;
  if (getenv("DSH_ANCHOR_TRACE") != nullptr) {
    NSLog(@"[anchor-trace] walking %@ (incoming error: %@)",
        physicalPath, error != nil && *error != nil
            ? (*error).localizedDescription : nil);
  }
  physicalPath = DSHApplyTrustedSystemAliases(physicalPath);
  NSArray<NSString *> *components = physicalPath.pathComponents;
  // Real-device sandboxes forbid openat() descent from "/" (EPERM outside
  // the container), so anchoring must start at the application container.
  // Everything up to and including the container root is opened through
  // realpath-verified absolute opens; only the container-relative tail is
  // strict-walked with O_NOFOLLOW.
  //
  // The container root is derived from the system API first:
  // NSHomeDirectory() names the app data container for both the device
  // layout /private/var/mobile/Containers/Data/Application/<UUID>/... and
  // the simulator layout <...>/CoreSimulator/Devices/<uuid>/data/
  // Containers/Data/Application/<uuid>/... . realpath() canonicalizes the
  // root where the sandbox permits it; on a real device realpath() fails on
  // the sandbox-external prefix, so the alias-rewritten home string is used
  // instead with the container shape as validation. Matching the container
  // shape inside the target itself is only a last-resort fallback for when
  // no root can be derived. A target outside the derived container is
  // refused outright: fail closed, no cross-container access.
  NSString *containerRootPath = nil;
  NSString *homePath = NSHomeDirectory();
  if (homePath.length > 0) {
    char resolvedHome[PATH_MAX] = {};
    if (realpath(homePath.fileSystemRepresentation, resolvedHome) != nullptr) {
      containerRootPath = DSHFileSystemString(resolvedHome);
    } else {
      NSString *physicalHome = DSHApplyTrustedSystemAliases(homePath);
      NSArray<NSString *> *homeComponents = physicalHome.pathComponents;
      NSUInteger homeRootIndex = DSHContainerAnchorIndex(
          @"last_app_container_index", @"index", homeComponents);
      if (homeRootIndex != NSNotFound &&
          homeRootIndex + 1 == homeComponents.count) {
        containerRootPath = physicalHome;
      }
    }
  }
  NSUInteger containerSegments = NSNotFound;
  if (containerRootPath != nil) {
    containerSegments =
        DSHContainerAnchorSegmentCountForPaths(physicalPath, containerRootPath);
    if (containerSegments == NSNotFound) {
      DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
      return -1;
    }
  } else {
    containerSegments = DSHContainerRootScanSegmentCount(physicalPath);
    if (containerSegments == NSNotFound) {
      DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
      return -1;
    }
  }
  if (getenv("DSH_ANCHOR_TRACE") != nullptr) {
    NSLog(@"[anchor-trace] container root %@, anchoring after component %lu",
        containerRootPath ?: @"(derived from target)",
        (unsigned long)containerSegments);
  }

  // Phase 1: open the trusted prefix with one absolute open (no descent
  // from "/"), then verify it is the directory the path names.
  NSMutableArray<NSString *> *prefix =
      [NSMutableArray arrayWithObject:@"/"];
  [prefix addObjectsFromArray:
      [components subarrayWithRange:NSMakeRange(1, containerSegments)]];
  NSString *prefixPath = [NSString pathWithComponents:prefix];
  struct stat prefixStat = {};
  if (lstat(prefixPath.fileSystemRepresentation, &prefixStat) != 0 ||
      !S_ISDIR(prefixStat.st_mode)) {
    DSHSetAccessError(error, stat(prefixPath.fileSystemRepresentation,
        &prefixStat) != 0 && errno == ENOENT
        ? DSHLocalProjectAccessErrorRootAbsent
        : DSHLocalProjectAccessErrorUnsafeStorage);
    return -1;
  }
  int descriptor = open(prefixPath.fileSystemRepresentation,
      O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (descriptor < 0) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorStorageUnavailable);
    return -1;
  }
  struct stat prefixVerify = {};
  if (fstat(descriptor, &prefixVerify) != 0 ||
      prefixVerify.st_dev != prefixStat.st_dev ||
      prefixVerify.st_ino != prefixStat.st_ino) {
    close(descriptor);
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return -1;
  }

  // Phase 2: strict no-follow walk of the remaining tail.
  for (NSUInteger index = containerSegments + 1;
      index < components.count; index++) {
    NSString *component = components[index];
    if (component.length == 0 || [component isEqual:@"/"] ||
        [component isEqual:@"."] || [component isEqual:@".."]) {
      close(descriptor);
      DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
      return -1;
    }
    if (index + 1 == components.count && hook != nil) {
      hook(@"before_projects_root_final_open");
    }
    struct stat before = {};
    errno = 0;
    int statResult = fstatat(descriptor, component.fileSystemRepresentation,
                             &before, AT_SYMLINK_NOFOLLOW);
    int failure = statResult == 0 ? 0 : errno;
    int next = statResult == 0 && S_ISDIR(before.st_mode)
        ? openat(descriptor, component.fileSystemRepresentation,
                 O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        : -1;
    if (next < 0 && failure == 0 && statResult == 0 && S_ISDIR(before.st_mode)) {
      failure = errno;
    }
    struct stat opened = {};
    BOOL valid = next >= 0 && fstat(next, &opened) == 0 &&
                 DSHSameNode(before, opened);
    close(descriptor);
    if (!valid) {
      if (next >= 0) close(next);
      if (getenv("DSH_ANCHOR_TRACE") != nullptr) {
        NSLog(@"[anchor-trace] component '%@' FAILED stat=%d failure=%d "
              @"next=%d isdir=%d",
            component, statResult, failure, next, S_ISDIR(before.st_mode));
      }
      DSHSetAccessError(error, statResult != 0 && failure == ENOENT
          ? DSHLocalProjectAccessErrorRootAbsent
          : DSHLocalProjectAccessErrorUnsafeStorage);
      return -1;
    }
    descriptor = next;
  }
  return descriptor;
}

static int DSHOpenPrivateChildDirectory(int parentDescriptor,
                                        const char *name,
                                        BOOL create,
                                        NSError **error) {
  struct stat before = {};
  if (fstatat(parentDescriptor, name, &before, AT_SYMLINK_NOFOLLOW) != 0) {
    int statFailure = errno;
    if (!create || statFailure != ENOENT ||
        mkdirat(parentDescriptor, name, 0700) != 0 ||
        fsync(parentDescriptor) != 0 ||
        fstatat(parentDescriptor, name, &before, AT_SYMLINK_NOFOLLOW) != 0) {
      DSHSetAccessError(error, !create && statFailure == ENOENT
          ? DSHLocalProjectAccessErrorRootAbsent
          : (!create ? DSHLocalProjectAccessErrorUnsafeStorage
                     : DSHLocalProjectAccessErrorStorageUnavailable));
      return -1;
    }
  }
  if (!S_ISDIR(before.st_mode)) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return -1;
  }
  int child = openat(parentDescriptor, name,
                     O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  struct stat opened = {};
  BOOL valid = child >= 0 && fstat(child, &opened) == 0 &&
               DSHSameNode(before, opened);
  if (!valid) {
    if (child >= 0) close(child);
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return -1;
  }
  if (create && fchmod(child, 0700) != 0) {
    close(child);
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return -1;
  }
  return child;
}

static BOOL DSHSameNode(const struct stat &left, const struct stat &right) {
  return left.st_dev == right.st_dev && left.st_ino == right.st_ino &&
         left.st_mode == right.st_mode;
}

static BOOL DSHForbiddenGitIndirectionAbsent(int gitDescriptor,
                                             int objectsDescriptor) {
  struct stat metadata = {};
  errno = 0;
  if (fstatat(gitDescriptor, "commondir", &metadata,
              AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT) {
    return NO;
  }
  int info = openat(objectsDescriptor, "info",
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (info < 0) return errno == ENOENT;
  BOOL safe = YES;
  const char *names[] = {"alternates", "http-alternates"};
  for (const char *name : names) {
    errno = 0;
    if (fstatat(info, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 ||
        errno != ENOENT) {
      safe = NO;
      break;
    }
  }
  close(info);
  return safe;
}

static void DSHEnsureLibgit2Lifetime(void) {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    // Deliberately process-lifetime. Per-module init/shutdown pairs can race
    // while another native service still owns repository objects.
    git_libgit2_init();
  });
}

@interface DSHProjectRWLock : NSObject {
  std::shared_timed_mutex _lock;
}
- (BOOL)lockForMode:(DSHLocalProjectAccessMode)mode
             timeout:(NSTimeInterval)timeout;
- (void)unlockForMode:(DSHLocalProjectAccessMode)mode;
@end

@implementation DSHProjectRWLock
- (BOOL)lockForMode:(DSHLocalProjectAccessMode)mode
             timeout:(NSTimeInterval)timeout {
  if (timeout < 0) {
    if (mode == DSHLocalProjectAccessModeWrite) {
      _lock.lock();
    } else {
      _lock.lock_shared();
    }
    return YES;
  }
  std::chrono::duration<double> duration(timeout);
  if (mode == DSHLocalProjectAccessModeWrite) {
    return _lock.try_lock_for(duration);
  } else {
    return _lock.try_lock_shared_for(duration);
  }
}
- (void)unlockForMode:(DSHLocalProjectAccessMode)mode {
  if (mode == DSHLocalProjectAccessModeWrite) {
    _lock.unlock();
  } else {
    _lock.unlock_shared();
  }
}
@end

@interface DSHLocalProjectLockToken ()
@property(nonatomic, strong) DSHProjectRWLock *projectLock;
@property(nonatomic, copy) NSString *projectId;
@property(nonatomic) DSHLocalProjectAccessMode mode;
@property(nonatomic) BOOL acquired;
- (instancetype)initWithLock:(DSHProjectRWLock *)projectLock
                    projectId:(NSString *)projectId
                         mode:(DSHLocalProjectAccessMode)mode
                      timeout:(NSTimeInterval)timeout;
@end

@implementation DSHLocalProjectLockToken
- (instancetype)initWithLock:(DSHProjectRWLock *)projectLock
                    projectId:(NSString *)projectId
                         mode:(DSHLocalProjectAccessMode)mode
                      timeout:(NSTimeInterval)timeout {
  self = [super init];
  if (self) {
    _projectLock = projectLock;
    _projectId = [projectId copy];
    _mode = mode;
    _acquired = [_projectLock lockForMode:mode timeout:timeout];
  }
  return self;
}
- (void)dealloc {
  if (_acquired) {
    [_projectLock unlockForMode:_mode];
  }
}
@end

@interface DSHLocalProjectsRootLease ()
@property(nonatomic, strong, readwrite) NSURL *rootURL;
@property(nonatomic, readwrite) int descriptor;
@property(nonatomic, readwrite) dev_t device;
@property(nonatomic, readwrite) ino_t inode;
@end

@implementation DSHLocalProjectsRootLease
- (instancetype)init {
  self = [super init];
  if (self) _descriptor = -1;
  return self;
}
- (void)dealloc {
  if (_descriptor >= 0) close(_descriptor);
}
@end

@interface DSHLocalProjectLease ()
@property(nonatomic, copy, readwrite) NSString *projectId;
@property(nonatomic, strong, readwrite) NSURL *projectDirectoryURL;
@property(nonatomic, strong, readwrite) NSURL *repositoryURL;
@property(nonatomic, copy, readwrite, nullable) NSDictionary *metadata;
@property(nonatomic, readwrite) int projectsRootDescriptor;
@property(nonatomic, readwrite) int projectDescriptor;
@property(nonatomic, readwrite) int repositoryDescriptor;
@property(nonatomic, readwrite) int gitDescriptor;
@property(nonatomic, readwrite) int objectsDescriptor;
@property(nonatomic, readwrite) dev_t projectsRootDevice;
@property(nonatomic, readwrite) ino_t projectsRootInode;
@property(nonatomic, readwrite) dev_t projectDevice;
@property(nonatomic, readwrite) ino_t projectInode;
@property(nonatomic, readwrite) dev_t repositoryDevice;
@property(nonatomic, readwrite) ino_t repositoryInode;
@property(nonatomic, readwrite) dev_t gitDevice;
@property(nonatomic, readwrite) ino_t gitInode;
@property(nonatomic, readwrite) dev_t objectsDevice;
@property(nonatomic, readwrite) ino_t objectsInode;
@property(nonatomic, readwrite) git_repository *repository;
@property(nonatomic, readwrite) DSHLocalProjectAccessMode accessMode;
@property(nonatomic, strong) DSHLocalProjectLockToken *lockToken;
@property(nonatomic, strong, nullable) DSHLocalWorkspaceLease *workspaceLease;
@property(nonatomic, strong, nullable) DSHLocalWorkspaceAccess *workspaceAccess;
@property(nonatomic, copy, readwrite, nullable) NSString *workspaceId;
@property(nonatomic, readwrite) NSUInteger workspaceBindingRevision;
@property(nonatomic, copy, readwrite, nullable) NSString *rootFingerprintSHA256;
@property(nonatomic, readwrite) int workspaceRootDescriptor;
@property(nonatomic, readwrite) dev_t workspaceRootDevice;
@property(nonatomic, readwrite) ino_t workspaceRootInode;
@property(nonatomic, copy, readwrite, nullable) NSDictionary *workspaceRootRef;
@property(nonatomic, copy, nullable) NSString *workspaceProjectComponent;
@property(nonatomic, copy, nullable) NSString *workspaceGitComponent;
@property(nonatomic, copy, nullable) NSString *workspacePath;
@property(nonatomic, copy, nullable) NSString *workspaceProjectMetadataDigest;
@property(nonatomic, copy, readwrite, nullable) NSString *gitTopology;
@property(nonatomic, strong, nullable) NSURL *workspaceGitDirectoryURL;
@property(nonatomic, copy, nullable) NSString *workspaceBindingDigest;
@property(nonatomic, copy, nullable) NSDictionary *workspaceBinding;
@property(nonatomic) BOOL workspaceBindingWasInjected;
@end

@implementation DSHLocalProjectLease
- (NSString *)rootFingerprint {
  return self.rootFingerprintSHA256;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _projectsRootDescriptor = -1;
    _projectDescriptor = -1;
    _repositoryDescriptor = -1;
    _gitDescriptor = -1;
    _objectsDescriptor = -1;
    _workspaceRootDescriptor = -1;
    _repository = nullptr;
  }
  return self;
}
- (void)dealloc {
  if (_repository != nullptr) git_repository_free(_repository);
  if (_objectsDescriptor >= 0) close(_objectsDescriptor);
  if (_gitDescriptor >= 0) close(_gitDescriptor);
  if (_repositoryDescriptor >= 0) close(_repositoryDescriptor);
  if (_projectDescriptor >= 0) close(_projectDescriptor);
  if (_projectsRootDescriptor >= 0) close(_projectsRootDescriptor);
  if (_workspaceRootDescriptor >= 0) close(_workspaceRootDescriptor);
  _lockToken = nil;
  _workspaceLease = nil;
}
@end

@interface DSHLocalProjectLeaseSet ()
@property(nonatomic, copy) NSDictionary<NSString *, DSHLocalProjectLease *> *leases;
@end

@implementation DSHLocalProjectLeaseSet
- (DSHLocalProjectLease *)leaseForProjectId:(NSString *)projectId {
  return self.leases[projectId];
}
@end

@interface DSHLocalProjectAccess ()
@property(nonatomic, strong, nullable) NSURL *injectedProjectsRootURL;
@property(nonatomic, strong, nullable) DSHLocalWorkspaceAccess *workspaceAccess;
@property(nonatomic, copy, nullable) DSHLocalProjectWorkspaceBindingResolver bindingResolver;
@property(nonatomic, copy, nullable) DSHLocalProjectAccessHook hook;
- (nullable NSDictionary *)workspaceBindingForRootRef:(NSDictionary *)rootRef
                                   rootFingerprintSHA256:(NSString *)rootFingerprint
                                              error:(NSError **)error;
- (nullable DSHLocalProjectLease *)leaseWorkspaceRootRef:(NSDictionary *)rootRef
                                         workspaceLease:(DSHLocalWorkspaceLease *)workspaceLease
                                       authorityAccess:(DSHLocalWorkspaceAccess *)authorityAccess
                                      workspaceBinding:(nullable NSDictionary *)workspaceBinding
                                                  mode:(DSHLocalProjectAccessMode)mode
                                       includeMetadata:(BOOL)includeMetadata
                                               timeout:(NSTimeInterval)timeout
                                                 error:(NSError **)error;
- (nullable NSURL *)resolvedProjectsRootCreatingIfNeeded:(BOOL)create
                                               descriptor:(nullable int *)descriptorOut
                                                    error:(NSError **)error;
@end

static NSString *DSHLocalProjectDescriptorPath(int descriptor) {
  if (descriptor < 0) return nil;
  char path[PATH_MAX] = {};
  if (fcntl(descriptor, F_GETPATH, path) != 0 || path[0] != '/') return nil;
  return [[NSFileManager defaultManager]
      stringWithFileSystemRepresentation:path length:strlen(path)];
}

static BOOL DSHLocalProjectSameStat(const struct stat &left,
                                    const struct stat &right) {
  return left.st_dev == right.st_dev && left.st_ino == right.st_ino &&
         left.st_mode == right.st_mode && left.st_nlink == right.st_nlink &&
         left.st_size == right.st_size &&
         left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec &&
         left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec &&
         left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec &&
         left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec;
}

static NSURL *DSHLocalProjectWorkspaceRootURL(
    DSHLocalWorkspaceAccess *workspaceAccess,
    NSDictionary *record) {
  if (workspaceAccess == nil ||
      ![record[@"root_locator_kind"] isEqual:@"documents_owned"] ||
      ![record[@"owned_directory_name"] isKindOfClass:NSString.class]) {
    return nil;
  }
  NSURL *container = workspaceAccess.ownedWorkspacesRootURL;
  NSString *directoryName = record[@"owned_directory_name"];
  return container == nil
      ? nil
      : [container URLByAppendingPathComponent:directoryName isDirectory:YES];
}

@implementation DSHLocalProjectAccess

- (NSDictionary *)workspaceBindingForRootRef:(NSDictionary *)rootRef
                         rootFingerprintSHA256:(NSString *)rootFingerprint
                                        error:(NSError **)error {
  if (!DSHLocalProjectCanonicalDigest(rootFingerprint)) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorRepositoryUnavailable);
    return nil;
  }
  NSDictionary *binding = nil;
  if (self.bindingResolver != nil) {
    @try {
      binding = self.bindingResolver(rootRef, rootFingerprint, error);
    } @catch (__unused NSException *exception) {
      DSHSetAccessError(error, DSHLocalProjectAccessErrorRepositoryUnavailable);
      return nil;
    }
  } else {
    // Production's default source is a private workspace-gitdirs binding.
    // It is deliberately not derived from project_id alone or from a global
    // projects path. The file is native-only and never crosses the bridge.
    NSURL *privateRoot = nil;
    @try {
      privateRoot = self.workspaceAccess.privateRootURL;
    } @catch (__unused NSException *exception) {
      privateRoot = nil;
    }
    NSString *workspaceId = rootRef[@"workspace_id"];
    NSString *projectId = rootRef[@"project_id"];
    if (privateRoot == nil || workspaceId.length == 0 || projectId.length == 0) {
      DSHSetAccessError(error, DSHLocalProjectAccessErrorRepositoryUnavailable);
      return nil;
    }
    // Read the native binding through a strict descriptor-relative walk. The
    // private root is trusted only as a location; every workspace/project
    // component and the final file are still opened with O_NOFOLLOW and
    // pinned against their fstatat/fstat identities.
    int privateDescriptor = DSHOpenAnchoredAbsoluteDirectory(
        privateRoot, self.hook, error);
    int gitdirsDescriptor = privateDescriptor >= 0
        ? DSHOpenPrivateChildDirectory(privateDescriptor, "workspace-gitdirs",
                                       NO, error)
        : -1;
    int workspaceDescriptor = gitdirsDescriptor >= 0
        ? DSHOpenPrivateChildDirectory(gitdirsDescriptor,
                                       workspaceId.fileSystemRepresentation,
                                       NO, error)
        : -1;
    int projectDescriptor = workspaceDescriptor >= 0
        ? DSHOpenPrivateChildDirectory(workspaceDescriptor,
                                       projectId.fileSystemRepresentation,
                                       NO, error)
        : -1;
    int descriptor = projectDescriptor >= 0
        ? openat(projectDescriptor, "binding-v2.json",
                 O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        : -1;
    struct stat metadata = {};
    BOOL valid = descriptor >= 0 && fstat(descriptor, &metadata) == 0 &&
        S_ISREG(metadata.st_mode) && metadata.st_nlink == 1 &&
        metadata.st_size > 0 && metadata.st_size <= 64 * 1024;
    NSMutableData *data = valid
        ? [NSMutableData dataWithLength:(NSUInteger)metadata.st_size] : nil;
    NSUInteger offset = 0;
    while (valid && offset < data.length) {
      ssize_t count = pread(descriptor,
                            static_cast<uint8_t *>(data.mutableBytes) + offset,
                            data.length - offset, (off_t)offset);
      if (count <= 0) {
        valid = NO;
        break;
      }
      offset += (NSUInteger)count;
    }
    struct stat after = {};
    valid = valid && fstat(descriptor, &after) == 0 &&
        DSHLocalProjectSameStat(metadata, after);
    struct stat pathAfter = {};
    valid = valid && projectDescriptor >= 0 &&
        fstatat(projectDescriptor, "binding-v2.json", &pathAfter,
                AT_SYMLINK_NOFOLLOW) == 0 &&
        DSHLocalProjectSameStat(metadata, pathAfter);
    if (descriptor >= 0) close(descriptor);
    if (projectDescriptor >= 0) close(projectDescriptor);
    if (workspaceDescriptor >= 0) close(workspaceDescriptor);
    if (gitdirsDescriptor >= 0) close(gitdirsDescriptor);
    if (privateDescriptor >= 0) close(privateDescriptor);
    NSDictionary *record = valid
        ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]
        : nil;
    if (![record isKindOfClass:NSDictionary.class] ||
        !DSHDictionaryHasExactKeys(record, @[
          @"schema_version", @"workspace_id", @"binding_revision",
          @"project_id", @"display_name", @"git_topology",
          @"git_directory_relative", @"root_fingerprint_sha256"
        ]) ||
        ![record[@"schema_version"] isEqual:@2] ||
        ![record[@"workspace_id"] isEqual:workspaceId] ||
        ![record[@"binding_revision"] isEqual:rootRef[@"binding_revision"]] ||
        ![record[@"project_id"] isEqual:projectId] ||
        ![record[@"root_fingerprint_sha256"] isEqual:rootFingerprint] ||
        ![record[@"git_topology"] isEqual:@"private_split_gitdir"]) {
      DSHSetAccessError(error, DSHLocalProjectAccessErrorMetadataInvalid);
      return nil;
    }
    NSString *relative = record[@"git_directory_relative"];
    BOOL relativeValid = [relative isKindOfClass:NSString.class];
    NSData *relativeBytes = relativeValid
        ? [relative dataUsingEncoding:NSUTF8StringEncoding
                    allowLossyConversion:NO]
        : nil;
    NSArray<NSString *> *components = relativeValid
        ? [relative componentsSeparatedByString:@"/"] : @[];
    relativeValid = relativeValid && relativeBytes != nil &&
        relativeBytes.length > 0 &&
        relativeBytes.length <= 1024 && ![relative hasPrefix:@"/"] &&
        ![relative containsString:@"\\"] && !DSHHasControlCharacter(relative);
    for (NSString *component in components) {
      relativeValid = relativeValid && component.length > 0 &&
          ![component isEqual:@"."] && ![component isEqual:@".."];
    }
    if (!relativeValid) {
      DSHSetAccessError(error, DSHLocalProjectAccessErrorMetadataInvalid);
      return nil;
    }
    NSURL *gitURL = privateRoot;
    for (NSString *component in components) {
      gitURL = [gitURL URLByAppendingPathComponent:component isDirectory:YES];
    }
    NSMutableDictionary *resolved = [record mutableCopy];
    [resolved removeObjectForKey:@"git_directory_relative"];
    resolved[@"git_directory_url"] = gitURL;
    binding = resolved;
  }
  if (!DSHLocalProjectBindingIsValid(binding, rootRef, rootFingerprint)) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorMetadataInvalid);
    return nil;
  }
  return [binding copy];
}

+ (instancetype)sharedAccess {
  static DSHLocalProjectAccess *access;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    access = [[DSHLocalProjectAccess alloc] initWithProjectsRootURL:nil];
  });
  return access;
}

+ (BOOL)isCanonicalProjectId:(NSString *)projectId {
  if (![projectId isKindOfClass:NSString.class] || projectId.length != 36 ||
      DSHHasControlCharacter(projectId)) {
    return NO;
  }
  NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:projectId];
  return uuid != nil &&
         [uuid.UUIDString.lowercaseString isEqualToString:projectId];
}

+ (NSString *)filesystemFoldedComponent:(NSString *)component {
  if (![component isKindOfClass:NSString.class] || component.length == 0) {
    return nil;
  }
  NSString *nfc = component.precomposedStringWithCanonicalMapping;
  NSMutableString *folded = [nfc mutableCopy];
  CFStringFold((__bridge CFMutableStringRef)folded,
               kCFCompareCaseInsensitive | kCFCompareWidthInsensitive,
               NULL);
  return folded.precomposedStringWithCanonicalMapping;
}

+ (NSString *)projectIdForWorkspacePath:(NSString *)path
                                   error:(NSError **)error {
  if (![path isKindOfClass:NSString.class] || path.length > 4096 ||
      [path hasPrefix:@"/"] || [path containsString:@"\\"] ||
      DSHHasControlCharacter(path)) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorInvalidIdentifier);
    return nil;
  }
  NSArray<NSString *> *components = [path componentsSeparatedByString:@"/"];
  NSString *rootComponent = components.firstObject;
  NSString *foldedRoot = [self filesystemFoldedComponent:rootComponent];
  if ([foldedRoot isEqual:@"projects"] &&
      ![rootComponent isEqual:@"projects"]) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorInvalidIdentifier);
    return nil;
  }
  if (components.count == 0 || ![rootComponent isEqual:@"projects"] ||
      components.count == 1) {
    return nil;
  }
  NSString *projectId = components[1];
  if (![self isCanonicalProjectId:projectId]) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorInvalidIdentifier);
    return nil;
  }
  return projectId;
}

+ (BOOL)validateWorkspaceRootRefV1:(NSDictionary *)rootRef
                    projectRequired:(BOOL)projectRequired
                              error:(NSError **)error {
  if (!DSHLocalProjectRootRefIsValid(rootRef, projectRequired, nullptr)) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorInvalidIdentifier);
    return NO;
  }
  return YES;
}

- (instancetype)init {
  return [self initWithProjectsRootURL:nil hook:nil];
}

- (instancetype)initWithProjectsRootURL:(NSURL *)projectsRootURL {
  return [self initWithProjectsRootURL:projectsRootURL hook:nil];
}

- (instancetype)initWithProjectsRootURL:(NSURL *)projectsRootURL
                                   hook:(DSHLocalProjectAccessHook)hook {
  return [self initWithProjectsRootURL:projectsRootURL
                       workspaceAccess:nil
                                  hook:hook];
}

- (instancetype)initWithWorkspaceAccess:(DSHLocalWorkspaceAccess *)workspaceAccess
                                    hook:(DSHLocalProjectAccessHook)hook {
  return [self initWithWorkspaceAccess:workspaceAccess
                       bindingResolver:nil
                                  hook:hook];
}

- (instancetype)initWithWorkspaceAccess:(DSHLocalWorkspaceAccess *)workspaceAccess
                        bindingResolver:(DSHLocalProjectWorkspaceBindingResolver)bindingResolver
                                    hook:(DSHLocalProjectAccessHook)hook {
  return [self initWithProjectsRootURL:nil
                       workspaceAccess:workspaceAccess
                      bindingResolver:bindingResolver
                                  hook:hook];
}

- (instancetype)initWithProjectsRootURL:(NSURL *)projectsRootURL
                        workspaceAccess:(DSHLocalWorkspaceAccess *)workspaceAccess
                                    hook:(DSHLocalProjectAccessHook)hook {
  return [self initWithProjectsRootURL:projectsRootURL
                       workspaceAccess:workspaceAccess
                      bindingResolver:nil
                                  hook:hook];
}

- (instancetype)initWithProjectsRootURL:(NSURL *)projectsRootURL
                        workspaceAccess:(DSHLocalWorkspaceAccess *)workspaceAccess
                       bindingResolver:(DSHLocalProjectWorkspaceBindingResolver)bindingResolver
                                    hook:(DSHLocalProjectAccessHook)hook {
  self = [super init];
  if (self) {
    DSHEnsureLibgit2Lifetime();
    _injectedProjectsRootURL = [projectsRootURL copy];
    _workspaceAccess = workspaceAccess;
    _bindingResolver = [bindingResolver copy];
    _hook = [hook copy];
  }
  return self;
}

static DSHProjectRWLock *DSHLockForProjectId(NSString *projectId) {
  static NSMutableDictionary<NSString *, DSHProjectRWLock *> *locks;
  static NSLock *guard;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    locks = [NSMutableDictionary dictionary];
    guard = [[NSLock alloc] init];
  });
  [guard lock];
  DSHProjectRWLock *lock = locks[projectId];
  if (lock == nil) {
    lock = [[DSHProjectRWLock alloc] init];
    locks[projectId] = lock;
  }
  [guard unlock];
  return lock;
}

- (NSURL *)projectsRootURLWithError:(NSError **)error {
  return [self resolvedProjectsRootCreatingIfNeeded:NO
                                         descriptor:nil error:error];
}

- (NSURL *)projectsRootURLCreatingIfNeeded:(BOOL)create
                                      error:(NSError **)error {
  return [self resolvedProjectsRootCreatingIfNeeded:create
                                         descriptor:nil error:error];
}

- (DSHLocalProjectsRootLease *)
    leaseProjectsRootCreatingIfNeeded:(BOOL)create
                                 error:(NSError **)error {
  int descriptor = -1;
  NSURL *rootURL = [self resolvedProjectsRootCreatingIfNeeded:create
                                                    descriptor:&descriptor
                                                         error:error];
  struct stat metadata = {};
  if (rootURL == nil || descriptor < 0 || fstat(descriptor, &metadata) != 0 ||
      !S_ISDIR(metadata.st_mode)) {
    if (descriptor >= 0) close(descriptor);
    if (error != nil && *error == nil) {
      DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    }
    return nil;
  }
  DSHLocalProjectsRootLease *lease =
      [[DSHLocalProjectsRootLease alloc] init];
  lease.rootURL = rootURL;
  lease.descriptor = descriptor;
  lease.device = metadata.st_dev;
  lease.inode = metadata.st_ino;
  return lease;
}

- (BOOL)validateProjectsRootLease:(DSHLocalProjectsRootLease *)lease
                             error:(NSError **)error {
  if (lease == nil || lease.descriptor < 0) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return NO;
  }
  struct stat retained = {};
  int currentDescriptor = -1;
  NSURL *currentURL = [self resolvedProjectsRootCreatingIfNeeded:NO
                                                       descriptor:&currentDescriptor
                                                            error:error];
  struct stat current = {};
  BOOL valid = currentURL != nil && currentDescriptor >= 0 &&
      fstat(lease.descriptor, &retained) == 0 &&
      fstat(currentDescriptor, &current) == 0 &&
      retained.st_dev == lease.device && retained.st_ino == lease.inode &&
      DSHSameNode(retained, current) && S_ISDIR(retained.st_mode);
  if (currentDescriptor >= 0) close(currentDescriptor);
  if (!valid) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
  }
  return valid;
}

- (NSURL *)resolvedProjectsRootCreatingIfNeeded:(BOOL)create
                                      descriptor:(int *)descriptorOut
                                           error:(NSError **)error {
  if (descriptorOut != nullptr) *descriptorOut = -1;
  NSURL *projects = self.injectedProjectsRootURL;
  int projectsDescriptor = -1;
  if (projects != nil) {
    // Injected roots are test/application-owned existing roots. Bootstrap is
    // deliberately unavailable because no trusted parent capability was
    // supplied with the URL.
    projectsDescriptor = DSHOpenAnchoredAbsoluteDirectory(
        projects, self.hook, error);
  } else {
    NSError *internalError = nil;
    NSURL *support = [[NSFileManager defaultManager]
        URLForDirectory:NSApplicationSupportDirectory
               inDomain:NSUserDomainMask
      appropriateForURL:nil
                 create:NO
                  error:&internalError];
    NSError *supportAccessError = nil;
    int supportDescriptor = support == nil ? -1 :
        DSHOpenAnchoredAbsoluteDirectory(support, nil, &supportAccessError);
    if (supportDescriptor < 0 && create) {
      NSURL *home = [NSURL fileURLWithPath:NSHomeDirectory()
                                isDirectory:YES];
      int homeDescriptor = DSHOpenAnchoredAbsoluteDirectory(home, nil, nil);
      int libraryDescriptor = homeDescriptor < 0 ? -1 :
          DSHOpenPrivateChildDirectory(homeDescriptor, "Library", YES, nil);
      supportDescriptor = libraryDescriptor < 0 ? -1 :
          DSHOpenPrivateChildDirectory(libraryDescriptor,
                                       "Application Support", YES, nil);
      if (libraryDescriptor >= 0) close(libraryDescriptor);
      if (homeDescriptor >= 0) close(homeDescriptor);
      support = [[home URLByAppendingPathComponent:@"Library" isDirectory:YES]
          URLByAppendingPathComponent:@"Application Support" isDirectory:YES];
    }
    if (supportDescriptor < 0) {
      if (error != nil && *error == nil) {
        *error = supportAccessError ?: DSHAccessError(
            DSHLocalProjectAccessErrorStorageUnavailable);
      }
      return nil;
    }
    int workspaceDescriptor = DSHOpenPrivateChildDirectory(
        supportDescriptor, "workspace", create, error);
    if (workspaceDescriptor >= 0 && self.hook != nil) {
      self.hook(@"before_projects_root_final_open");
    }
    projectsDescriptor = workspaceDescriptor < 0 ? -1 :
        DSHOpenPrivateChildDirectory(workspaceDescriptor, "projects", create,
                                     error);
    if (workspaceDescriptor >= 0) close(workspaceDescriptor);
    close(supportDescriptor);
    projects = [[support URLByAppendingPathComponent:@"workspace" isDirectory:YES]
        URLByAppendingPathComponent:@"projects" isDirectory:YES];
  }
  if (projectsDescriptor < 0) return nil;
  if (create) {
    struct stat retainedBefore = {};
    int visibleBeforeDescriptor = DSHOpenAnchoredAbsoluteDirectory(
        projects, nil, nil);
    struct stat visibleBefore = {};
    BOOL visibleBeforeBound = fstat(projectsDescriptor, &retainedBefore) == 0 &&
        visibleBeforeDescriptor >= 0 &&
        fstat(visibleBeforeDescriptor, &visibleBefore) == 0 &&
        DSHSameNode(retainedBefore, visibleBefore);
    if (visibleBeforeDescriptor >= 0) close(visibleBeforeDescriptor);
    if (!visibleBeforeBound) {
      close(projectsDescriptor);
      DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
      return nil;
    }
    NSError *attributeError = nil;
    BOOL backupExcluded = [projects setResourceValue:@YES
                                               forKey:NSURLIsExcludedFromBackupKey
                                                error:&attributeError];
    BOOL attributesApplied = [[NSFileManager defaultManager]
        setAttributes:@{
          NSFilePosixPermissions : @0700,
          NSFileProtectionKey :
              NSFileProtectionCompleteUntilFirstUserAuthentication,
        }
         ofItemAtPath:projects.path
                error:&attributeError];
    if (!backupExcluded || !attributesApplied) {
      close(projectsDescriptor);
      DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
      return nil;
    }
    int visibleAfterDescriptor = DSHOpenAnchoredAbsoluteDirectory(
        projects, nil, nil);
    struct stat retainedAfter = {};
    struct stat visibleAfter = {};
    BOOL visibleAfterBound = fstat(projectsDescriptor, &retainedAfter) == 0 &&
        visibleAfterDescriptor >= 0 &&
        fstat(visibleAfterDescriptor, &visibleAfter) == 0 &&
        DSHSameNode(retainedBefore, retainedAfter) &&
        DSHSameNode(retainedAfter, visibleAfter);
    if (visibleAfterDescriptor >= 0) close(visibleAfterDescriptor);
    if (!visibleAfterBound) {
      close(projectsDescriptor);
      DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
      return nil;
    }
  }
  if (descriptorOut != nullptr) {
    *descriptorOut = projectsDescriptor;
  } else {
    close(projectsDescriptor);
  }
  return projects;
}

- (NSURL *)projectDirectoryURLForId:(NSString *)projectId
                               error:(NSError **)error {
  if (![DSHLocalProjectAccess isCanonicalProjectId:projectId]) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorInvalidIdentifier);
    return nil;
  }
  DSHLocalProjectsRootLease *rootLease =
      [self leaseProjectsRootCreatingIfNeeded:NO error:error];
  if (rootLease == nil) return nil;
  struct stat before = {};
  int descriptor = fstatat(rootLease.descriptor, projectId.UTF8String, &before,
                           AT_SYMLINK_NOFOLLOW) == 0 && S_ISDIR(before.st_mode)
      ? openat(rootLease.descriptor, projectId.UTF8String,
               O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      : -1;
  struct stat opened = {};
  BOOL valid = descriptor >= 0 && fstat(descriptor, &opened) == 0 &&
               DSHSameNode(before, opened);
  if (descriptor >= 0) close(descriptor);
  if (!valid) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorStorageUnavailable);
    return nil;
  }
  return [rootLease.rootURL URLByAppendingPathComponent:projectId
                                             isDirectory:YES];
}

- (DSHLocalProjectLockToken *)lockProjectId:(NSString *)projectId
                                       mode:(DSHLocalProjectAccessMode)mode
                                      error:(NSError **)error {
  if (![DSHLocalProjectAccess isCanonicalProjectId:projectId] ||
      (mode != DSHLocalProjectAccessModeRead &&
       mode != DSHLocalProjectAccessModeWrite)) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorInvalidIdentifier);
    return nil;
  }
  return [[DSHLocalProjectLockToken alloc]
      initWithLock:DSHLockForProjectId(projectId)
         projectId:projectId
              mode:mode
           timeout:-1];
}

- (DSHLocalProjectLockToken *)tryLockProjectIdForWrite:(NSString *)projectId
                                                  error:(NSError **)error {
  if (![DSHLocalProjectAccess isCanonicalProjectId:projectId]) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorInvalidIdentifier);
    return nil;
  }
  DSHLocalProjectLockToken *token = [[DSHLocalProjectLockToken alloc]
      initWithLock:DSHLockForProjectId(projectId)
         projectId:projectId
              mode:DSHLocalProjectAccessModeWrite
           timeout:0];
  if (!token.acquired) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorLockTimeout);
    return nil;
  }
  return token;
}

static NSDictionary *DSHReadMetadata(int projectDescriptor,
                                     dev_t projectDevice,
                                     NSString *projectId,
                                     NSString **digestOut,
                                     NSError **error) {
  int descriptor = openat(projectDescriptor, "project.json",
                          O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (descriptor < 0) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorMetadataInvalid);
    return nil;
  }
  struct stat metadata = {};
  BOOL valid = fstat(descriptor, &metadata) == 0 &&
               S_ISREG(metadata.st_mode) && metadata.st_nlink == 1 &&
               metadata.st_dev == projectDevice &&
               metadata.st_size >= 2 &&
               metadata.st_size <= (off_t)DSHProjectMetadataMaxBytes;
  NSMutableData *data = valid
                            ? [NSMutableData dataWithLength:(NSUInteger)metadata.st_size]
                            : nil;
  ssize_t offset = 0;
  while (valid && offset < metadata.st_size) {
    ssize_t count = pread(descriptor,
                          static_cast<uint8_t *>(data.mutableBytes) + offset,
                          (size_t)(metadata.st_size - offset), offset);
    if (count <= 0) {
      valid = NO;
      break;
    }
    offset += count;
  }
  struct stat after = {};
  valid = valid && fstat(descriptor, &after) == 0 &&
          metadata.st_dev == after.st_dev && metadata.st_ino == after.st_ino &&
          metadata.st_mode == after.st_mode &&
          metadata.st_size == after.st_size && metadata.st_nlink == after.st_nlink &&
          metadata.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec &&
          metadata.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
          metadata.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec &&
          metadata.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec;
  struct stat pathAfter = {};
  valid = valid &&
          fstatat(projectDescriptor, "project.json", &pathAfter,
                  AT_SYMLINK_NOFOLLOW) == 0 &&
          metadata.st_dev == pathAfter.st_dev &&
          metadata.st_ino == pathAfter.st_ino &&
          metadata.st_mode == pathAfter.st_mode &&
          metadata.st_size == pathAfter.st_size &&
          metadata.st_nlink == pathAfter.st_nlink &&
          metadata.st_mtimespec.tv_sec == pathAfter.st_mtimespec.tv_sec &&
          metadata.st_mtimespec.tv_nsec == pathAfter.st_mtimespec.tv_nsec &&
          metadata.st_ctimespec.tv_sec == pathAfter.st_ctimespec.tv_sec &&
          metadata.st_ctimespec.tv_nsec == pathAfter.st_ctimespec.tv_nsec;
  close(descriptor);
  NSDictionary *object = valid
                             ? [NSJSONSerialization JSONObjectWithData:data
                                                               options:0
                                                                 error:nil]
                             : nil;
  if (![object isKindOfClass:NSDictionary.class]) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorMetadataInvalid);
    return nil;
  }
  NSString *name = [object[@"name"] isKindOfClass:NSString.class]
                       ? object[@"name"]
                       : nil;
  NSString *created = [object[@"created_at"] isKindOfClass:NSString.class]
                          ? object[@"created_at"]
                          : nil;
  NSString *updated = [object[@"updated_at"] isKindOfClass:NSString.class]
                          ? object[@"updated_at"]
                          : nil;
  id origin = object[@"origin_url"];
  BOOL originValid = origin == nil || origin == NSNull.null ||
                     [origin isKindOfClass:NSString.class];
  NSUInteger nameBytes = [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
  if (!DSHDictionaryHasExactKeys(object, @[
        @"schema_version", @"name", @"created_at", @"updated_at",
        @"origin_url"
      ]) ||
      ![object[@"schema_version"] isEqual:@1] || nameBytes == 0 ||
      nameBytes > 120 || DSHHasControlCharacter(name) ||
      [name containsString:@"/"] || [name containsString:@"\\"] ||
      created.length < 20 || created.length > 64 || updated.length < 20 ||
      updated.length > 64 || DSHHasControlCharacter(created) ||
      DSHHasControlCharacter(updated) || !originValid) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorMetadataInvalid);
    return nil;
  }
  if (digestOut != nullptr) {
    uint8_t digest[CC_SHA256_DIGEST_LENGTH] = {};
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString
        stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
      [hex appendFormat:@"%02x", digest[index]];
    }
    *digestOut = hex;
  }
  return @{
    @"schema_version" : @1,
    @"id" : projectId,
    @"name" : name,
    @"workspace_path" :
        [NSString stringWithFormat:@"projects/%@/repo", projectId],
    @"created_at" : created,
    @"updated_at" : updated,
    @"origin_url" : origin ?: NSNull.null,
  };
}

static BOOL DSHValidStoredMetadataRecord(NSDictionary *record) {
  return [DSHLocalProjectReduce(@"stored_metadata_valid", @{
    @"record" : [record isKindOfClass:NSDictionary.class] ? record
                                                          : NSNull.null,
  })[@"valid"] isEqual:@YES];
}

static BOOL DSHWriteAllBytes(int descriptor, NSData *data) {
  const uint8_t *bytes = static_cast<const uint8_t *>(data.bytes);
  NSUInteger offset = 0;
  while (offset < data.length) {
    ssize_t count = write(descriptor, bytes + offset, data.length - offset);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) return NO;
    offset += (NSUInteger)count;
  }
  return YES;
}

static BOOL DSHWriteProjectMetadataRecord(NSDictionary *record,
                                          int projectDescriptor,
                                          NSError **error);

- (DSHLocalProjectLease *)leaseProjectId:(NSString *)projectId
                                     mode:(DSHLocalProjectAccessMode)mode
                          includeMetadata:(BOOL)includeMetadata
                                    error:(NSError **)error {
  return [self leaseProjectId:projectId
                         mode:mode
              includeMetadata:includeMetadata
                      timeout:-1
                        error:error];
}

- (DSHLocalProjectLease *)leaseProjectId:(NSString *)projectId
                                     mode:(DSHLocalProjectAccessMode)mode
                          includeMetadata:(BOOL)includeMetadata
                                  timeout:(NSTimeInterval)timeout
                                    error:(NSError **)error {
  if (![DSHLocalProjectAccess isCanonicalProjectId:projectId] ||
      (mode != DSHLocalProjectAccessModeRead &&
       mode != DSHLocalProjectAccessModeWrite) ||
      !isfinite(timeout)) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorInvalidIdentifier);
    return nil;
  }
  DSHLocalProjectLockToken *token = [[DSHLocalProjectLockToken alloc]
      initWithLock:DSHLockForProjectId(projectId)
         projectId:projectId
              mode:mode
           timeout:timeout];
  if (!token.acquired) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorLockTimeout);
    return nil;
  }
  if (token == nil) return nil;
  int rootDescriptor = -1;
  NSURL *rootURL = [self resolvedProjectsRootCreatingIfNeeded:NO
                                                   descriptor:&rootDescriptor
                                                        error:error];
  if (rootURL == nil) return nil;
  if (self.hook != nil) self.hook(@"after_root_open");
  int projectDescriptor = rootDescriptor < 0
                              ? -1
                              : openat(rootDescriptor, projectId.UTF8String,
                                       O_RDONLY | O_DIRECTORY | O_CLOEXEC |
                                           O_NOFOLLOW);
  if (self.hook != nil) self.hook(@"after_project_open");
  int repositoryDescriptor = projectDescriptor < 0
                                 ? -1
                                 : openat(projectDescriptor, "repo",
                                          O_RDONLY | O_DIRECTORY | O_CLOEXEC |
                                              O_NOFOLLOW);
  if (self.hook != nil) self.hook(@"after_repo_open");
  int gitDescriptor = repositoryDescriptor < 0
                          ? -1
                          : openat(repositoryDescriptor, ".git",
                                   O_RDONLY | O_DIRECTORY | O_CLOEXEC |
                                       O_NOFOLLOW);
  if (self.hook != nil) self.hook(@"after_git_open");
  int objectsDescriptor = gitDescriptor < 0
                              ? -1
                              : openat(gitDescriptor, "objects",
                                       O_RDONLY | O_DIRECTORY | O_CLOEXEC |
                                           O_NOFOLLOW);
  struct stat rootMetadata = {};
  struct stat projectMetadata = {};
  struct stat repositoryMetadata = {};
  struct stat gitMetadata = {};
  struct stat objectsMetadata = {};
  BOOL safe = rootDescriptor >= 0 && projectDescriptor >= 0 &&
              repositoryDescriptor >= 0 && gitDescriptor >= 0 &&
              objectsDescriptor >= 0 &&
              fstat(rootDescriptor, &rootMetadata) == 0 &&
              fstat(projectDescriptor, &projectMetadata) == 0 &&
              fstat(repositoryDescriptor, &repositoryMetadata) == 0 &&
              fstat(gitDescriptor, &gitMetadata) == 0 &&
              fstat(objectsDescriptor, &objectsMetadata) == 0 &&
              S_ISDIR(rootMetadata.st_mode) &&
              S_ISDIR(projectMetadata.st_mode) &&
              S_ISDIR(repositoryMetadata.st_mode) &&
              S_ISDIR(gitMetadata.st_mode) &&
              S_ISDIR(objectsMetadata.st_mode) &&
              rootMetadata.st_dev == projectMetadata.st_dev &&
              rootMetadata.st_dev == repositoryMetadata.st_dev &&
              rootMetadata.st_dev == gitMetadata.st_dev &&
              rootMetadata.st_dev == objectsMetadata.st_dev &&
              DSHForbiddenGitIndirectionAbsent(gitDescriptor,
                                               objectsDescriptor);
  if (!safe) {
    if (objectsDescriptor >= 0) close(objectsDescriptor);
    if (gitDescriptor >= 0) close(gitDescriptor);
    if (repositoryDescriptor >= 0) close(repositoryDescriptor);
    if (projectDescriptor >= 0) close(projectDescriptor);
    if (rootDescriptor >= 0) close(rootDescriptor);
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return nil;
  }
  NSURL *projectURL =
      [rootURL URLByAppendingPathComponent:projectId isDirectory:YES];
  NSURL *repositoryURL =
      [projectURL URLByAppendingPathComponent:@"repo" isDirectory:YES];
  if (self.hook != nil) self.hook(@"before_libgit_open");
  git_repository *repository = nullptr;
  int result = git_repository_open_ext(&repository,
                                       repositoryURL.fileSystemRepresentation,
                                       GIT_REPOSITORY_OPEN_NO_SEARCH, nullptr);
  if (self.hook != nil) self.hook(@"after_libgit_open");
  const char *workdir = repository == nullptr ? nullptr
                                               : git_repository_workdir(repository);
  NSString *actual = workdir == nullptr
                         ? nil
                         : [[NSFileManager defaultManager]
                               stringWithFileSystemRepresentation:workdir
                                                            length:strlen(workdir)];
  NSString *expected = repositoryURL.path.stringByStandardizingPath;
  struct stat projectAfter = {};
  struct stat repositoryAfter = {};
  BOOL descriptorsStillCanonical =
      fstatat(rootDescriptor, projectId.UTF8String, &projectAfter,
              AT_SYMLINK_NOFOLLOW) == 0 &&
      fstatat(projectDescriptor, "repo", &repositoryAfter,
              AT_SYMLINK_NOFOLLOW) == 0 &&
      projectMetadata.st_dev == projectAfter.st_dev &&
      projectMetadata.st_ino == projectAfter.st_ino &&
      projectMetadata.st_mode == projectAfter.st_mode &&
      repositoryMetadata.st_dev == repositoryAfter.st_dev &&
      repositoryMetadata.st_ino == repositoryAfter.st_ino &&
      repositoryMetadata.st_mode == repositoryAfter.st_mode;
  if (result < 0 || repository == nullptr || git_repository_is_bare(repository) ||
      actual == nil ||
      ![actual.stringByStandardizingPath isEqualToString:expected] ||
      !descriptorsStillCanonical) {
    if (repository != nullptr) git_repository_free(repository);
    close(objectsDescriptor);
    close(gitDescriptor);
    close(repositoryDescriptor);
    close(projectDescriptor);
    close(rootDescriptor);
    DSHSetAccessError(error,
                      DSHLocalProjectAccessErrorRepositoryUnavailable);
    return nil;
  }
  NSDictionary *metadata = includeMetadata
                               ? DSHReadMetadata(projectDescriptor,
                                                 projectMetadata.st_dev,
                                                 projectId, nil, error)
                               : nil;
  if (includeMetadata && metadata == nil) {
    git_repository_free(repository);
    close(objectsDescriptor);
    close(gitDescriptor);
    close(repositoryDescriptor);
    close(projectDescriptor);
    close(rootDescriptor);
    return nil;
  }
  DSHLocalProjectLease *lease = [[DSHLocalProjectLease alloc] init];
  lease.projectId = projectId;
  lease.projectDirectoryURL = projectURL;
  lease.repositoryURL = repositoryURL;
  lease.metadata = metadata;
  lease.projectsRootDescriptor = rootDescriptor;
  lease.projectDescriptor = projectDescriptor;
  lease.repositoryDescriptor = repositoryDescriptor;
  lease.gitDescriptor = gitDescriptor;
  lease.objectsDescriptor = objectsDescriptor;
  lease.projectsRootDevice = rootMetadata.st_dev;
  lease.projectsRootInode = rootMetadata.st_ino;
  lease.projectDevice = projectMetadata.st_dev;
  lease.projectInode = projectMetadata.st_ino;
  lease.repositoryDevice = repositoryMetadata.st_dev;
  lease.repositoryInode = repositoryMetadata.st_ino;
  lease.gitDevice = gitMetadata.st_dev;
  lease.gitInode = gitMetadata.st_ino;
  lease.objectsDevice = objectsMetadata.st_dev;
  lease.objectsInode = objectsMetadata.st_ino;
  lease.repository = repository;
  lease.accessMode = mode;
  lease.lockToken = token;
  if (![self validateLeaseIdentity:lease error:error]) return nil;
  return lease;
}

static NSString *DSHFileSystemString(const char *path) {
  if (path == nullptr) return nil;
  return [[NSFileManager defaultManager]
      stringWithFileSystemRepresentation:path length:strlen(path)];
}

static BOOL DSHPathsEqual(NSString *left, NSString *right) {
  return left != nil && right != nil &&
         [left.stringByStandardizingPath
             isEqual:right.stringByStandardizingPath];
}

- (BOOL)validateLeaseIdentity:(DSHLocalProjectLease *)lease
                         error:(NSError **)error {
  if (lease.workspaceLease != nil) {
    return [self validateWorkspaceLeaseIdentity:lease
                                         rootRef:lease.workspaceRootRef
                                           error:error];
  }
  if (lease == nil || lease.repository == nullptr ||
      lease.projectsRootDescriptor < 0 || lease.projectDescriptor < 0 ||
      lease.repositoryDescriptor < 0 || lease.gitDescriptor < 0 ||
      lease.objectsDescriptor < 0) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return NO;
  }
  if (self.hook != nil) self.hook(@"before_identity_recheck");
  struct stat rootFD = {};
  struct stat projectFD = {};
  struct stat repoFD = {};
  struct stat gitFD = {};
  struct stat objectsFD = {};
  struct stat rootPath = {};
  struct stat projectPath = {};
  struct stat repoPath = {};
  struct stat gitPath = {};
  struct stat objectsPath = {};
  NSURL *rootURL = lease.projectDirectoryURL.URLByDeletingLastPathComponent;
  BOOL topology =
      fstat(lease.projectsRootDescriptor, &rootFD) == 0 &&
      fstat(lease.projectDescriptor, &projectFD) == 0 &&
      fstat(lease.repositoryDescriptor, &repoFD) == 0 &&
      fstat(lease.gitDescriptor, &gitFD) == 0 &&
      fstat(lease.objectsDescriptor, &objectsFD) == 0 &&
      lstat(rootURL.fileSystemRepresentation, &rootPath) == 0 &&
      fstatat(lease.projectsRootDescriptor, lease.projectId.UTF8String,
              &projectPath, AT_SYMLINK_NOFOLLOW) == 0 &&
      fstatat(lease.projectDescriptor, "repo", &repoPath,
              AT_SYMLINK_NOFOLLOW) == 0 &&
      fstatat(lease.repositoryDescriptor, ".git", &gitPath,
              AT_SYMLINK_NOFOLLOW) == 0 &&
      fstatat(lease.gitDescriptor, "objects", &objectsPath,
              AT_SYMLINK_NOFOLLOW) == 0 &&
      S_ISDIR(rootPath.st_mode) && S_ISDIR(projectPath.st_mode) &&
      S_ISDIR(repoPath.st_mode) && S_ISDIR(gitPath.st_mode) &&
      S_ISDIR(objectsPath.st_mode) && DSHSameNode(rootFD, rootPath) &&
      DSHSameNode(projectFD, projectPath) && DSHSameNode(repoFD, repoPath) &&
      DSHSameNode(gitFD, gitPath) && DSHSameNode(objectsFD, objectsPath) &&
      rootFD.st_dev == projectFD.st_dev && rootFD.st_dev == repoFD.st_dev &&
      rootFD.st_dev == gitFD.st_dev && rootFD.st_dev == objectsFD.st_dev &&
      DSHForbiddenGitIndirectionAbsent(lease.gitDescriptor,
                                       lease.objectsDescriptor);
  if (!topology) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return NO;
  }

  NSURL *gitURL = [lease.repositoryURL URLByAppendingPathComponent:@".git"
                                                        isDirectory:YES];
  NSURL *objectsURL = [gitURL URLByAppendingPathComponent:@"objects"
                                               isDirectory:YES];
  NSString *repoPathString = lease.repositoryURL.path;
  NSString *gitPathString = gitURL.path;
  NSString *objectsPathString = objectsURL.path;
  BOOL libgitPaths =
      DSHPathsEqual(DSHFileSystemString(git_repository_workdir(lease.repository)),
                    repoPathString) &&
      DSHPathsEqual(DSHFileSystemString(git_repository_path(lease.repository)),
                    gitPathString) &&
      DSHPathsEqual(DSHFileSystemString(git_repository_commondir(lease.repository)),
                    gitPathString);
  for (git_repository_item_t item : {
         GIT_REPOSITORY_ITEM_GITDIR, GIT_REPOSITORY_ITEM_COMMONDIR,
         GIT_REPOSITORY_ITEM_OBJECTS, GIT_REPOSITORY_ITEM_WORKDIR
       }) {
    git_buf value = GIT_BUF_INIT;
    int result = git_repository_item_path(&value, lease.repository, item);
    NSString *expected = item == GIT_REPOSITORY_ITEM_OBJECTS
        ? objectsPathString
        : (item == GIT_REPOSITORY_ITEM_WORKDIR ? repoPathString
                                               : gitPathString);
    NSString *actual = result == 0 && value.ptr != nullptr
        ? DSHFileSystemString(value.ptr)
        : nil;
    libgitPaths = libgitPaths && result == 0 && DSHPathsEqual(actual, expected);
    git_buf_dispose(&value);
  }
  if (!libgitPaths) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return NO;
  }
  return YES;
}

- (NSDictionary *)readProjectMetadataFromLease:(DSHLocalProjectLease *)lease
                                          error:(NSError **)error {
  if (lease.workspaceLease != nil) {
    if (![self validateWorkspaceLeaseIdentity:lease
                                       rootRef:lease.workspaceRootRef
                                         error:error]) {
      return nil;
    }
    return [lease.metadata copy];
  }
  if (![self validateLeaseIdentity:lease error:error]) return nil;
  NSDictionary *metadata = DSHReadMetadata(lease.projectDescriptor,
                                           lease.projectDevice,
                                           lease.projectId, nil, error);
  if (metadata == nil || ![self validateLeaseIdentity:lease error:error]) {
    return nil;
  }
  return metadata;
}

- (NSString *)projectMetadataDigestFromLease:(DSHLocalProjectLease *)lease
                                        error:(NSError **)error {
  if (lease.workspaceLease != nil) {
    if (![self validateWorkspaceLeaseIdentity:lease
                                       rootRef:lease.workspaceRootRef
                                         error:error]) {
      return nil;
    }
    return [lease.workspaceProjectMetadataDigest copy];
  }
  if (![self validateLeaseIdentity:lease error:error]) return nil;
  NSString *digest = nil;
  NSDictionary *metadata = DSHReadMetadata(lease.projectDescriptor,
                                           lease.projectDevice,
                                           lease.projectId, &digest, error);
  if (metadata == nil || digest == nil ||
      ![self validateLeaseIdentity:lease error:error]) {
    return nil;
  }
  return digest;
}

static BOOL DSHLocalProjectCanonicalLegacyDisplayName(id value) {
  NSString *trimmed = [value isKindOfClass:NSString.class]
      ? [value stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet]
      : nil;
  return [DSHLocalProjectReduce(@"legacy_display_name", @{
    @"value" : value ?: NSNull.null,
    @"foundation_trimmed" : trimmed ?: NSNull.null,
  })[@"valid"] isEqual:@YES];
}

static BOOL DSHLocalProjectLegacyEvidenceNode(
    int descriptor,
    dev_t expectedDevice,
    ino_t expectedInode,
    int parentDescriptor,
    const char *name,
    NSURL *absoluteURL) {
  struct stat descriptorState = {};
  struct stat pathState = {};
  BOOL pathRead = parentDescriptor >= 0 && name != nullptr
      ? fstatat(parentDescriptor, name, &pathState, AT_SYMLINK_NOFOLLOW) == 0
      : absoluteURL != nil &&
          lstat(absoluteURL.fileSystemRepresentation, &pathState) == 0;
  return descriptor >= 0 && fstat(descriptor, &descriptorState) == 0 &&
      pathRead && S_ISDIR(descriptorState.st_mode) &&
      S_ISDIR(pathState.st_mode) && !S_ISLNK(pathState.st_mode) &&
      descriptorState.st_nlink > 0 && pathState.st_nlink > 0 &&
      descriptorState.st_dev == expectedDevice &&
      descriptorState.st_ino == expectedInode &&
      descriptorState.st_dev == pathState.st_dev &&
      descriptorState.st_ino == pathState.st_ino &&
      (descriptorState.st_mode & S_IFMT) == (pathState.st_mode & S_IFMT) &&
      descriptorState.st_nlink == pathState.st_nlink;
}

- (NSDictionary *)legacyWorkspaceBootstrapEvidenceForProjectId:
    (NSString *)projectId error:(NSError **)error {
  DSHLocalProjectLease *lease = [self leaseProjectId:projectId
                                                mode:DSHLocalProjectAccessModeRead
                                     includeMetadata:NO
                                             timeout:-1
                                               error:error];
  if (lease == nil) return nil;
  if (![self validateLeaseIdentity:lease error:error]) return nil;

  NSString *metadataDigest = nil;
  NSDictionary *metadata = DSHReadMetadata(lease.projectDescriptor,
                                            lease.projectDevice,
                                            lease.projectId,
                                            &metadataDigest, error);
  NSString *displayName = metadata[@"name"];
  if (metadata == nil ||
      !DSHLocalProjectCanonicalDigest(metadataDigest) ||
      !DSHLocalProjectCanonicalLegacyDisplayName(displayName)) {
    if (error != nil && *error == nil) {
      DSHSetAccessError(error, DSHLocalProjectAccessErrorMetadataInvalid);
    }
    return nil;
  }

  NSURL *projectsRootURL =
      lease.projectDirectoryURL.URLByDeletingLastPathComponent;
  BOOL physicalIdentityValid =
      DSHLocalProjectLegacyEvidenceNode(
          lease.projectsRootDescriptor, lease.projectsRootDevice,
          lease.projectsRootInode, -1, nullptr, projectsRootURL) &&
      DSHLocalProjectLegacyEvidenceNode(
          lease.repositoryDescriptor, lease.repositoryDevice,
          lease.repositoryInode, lease.projectDescriptor, "repo", nil) &&
      DSHLocalProjectLegacyEvidenceNode(
          lease.gitDescriptor, lease.gitDevice, lease.gitInode,
          lease.repositoryDescriptor, ".git", nil) &&
      [self validateLeaseIdentity:lease error:error];
  if (!physicalIdentityValid) {
    if (error != nil && *error == nil) {
      DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    }
    return nil;
  }

  return @{
    @"project_id" : [lease.projectId copy],
    @"display_name" : [displayName copy],
    @"metadata_sha256" : metadataDigest,
    @"capabilities" : [NSSet setWithObjects:
        @"read", @"write", @"git", @"project_context", nil],
    @"projects_root_device_id" :
        [NSString stringWithFormat:@"%llu",
            (unsigned long long)lease.projectsRootDevice],
    @"projects_root_inode_id" :
        [NSString stringWithFormat:@"%llu",
            (unsigned long long)lease.projectsRootInode],
    @"repository_device_id" :
        [NSString stringWithFormat:@"%llu",
            (unsigned long long)lease.repositoryDevice],
    @"repository_inode_id" :
        [NSString stringWithFormat:@"%llu",
            (unsigned long long)lease.repositoryInode],
    @"git_device_id" :
        [NSString stringWithFormat:@"%llu",
            (unsigned long long)lease.gitDevice],
    @"git_inode_id" :
        [NSString stringWithFormat:@"%llu",
            (unsigned long long)lease.gitInode],
  };
}

- (BOOL)writeProjectMetadataRecord:(NSDictionary *)record
                             lease:(DSHLocalProjectLease *)lease
                             error:(NSError **)error {
  if (lease.accessMode != DSHLocalProjectAccessModeWrite ||
      ![self validateLeaseIdentity:lease error:error]) {
    if (lease.accessMode != DSHLocalProjectAccessModeWrite) {
      DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    }
    return NO;
  }
  if (!DSHWriteProjectMetadataRecord(record, lease.projectDescriptor, error)) {
    return NO;
  }
  return [self validateLeaseIdentity:lease error:error];
}

- (BOOL)writeInitialProjectMetadataRecord:(NSDictionary *)record
                                 projectId:(NSString *)projectId
                         projectDescriptor:(int)projectDescriptor
                                writeToken:(DSHLocalProjectLockToken *)writeToken
                                     error:(NSError **)error {
  if (![DSHLocalProjectAccess isCanonicalProjectId:projectId] ||
      writeToken == nil || !writeToken.acquired ||
      writeToken.mode != DSHLocalProjectAccessModeWrite ||
      ![writeToken.projectId isEqual:projectId] || projectDescriptor < 0) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return NO;
  }
  int rootDescriptor = -1;
  BOOL rootResolved = [self resolvedProjectsRootCreatingIfNeeded:NO
                                                     descriptor:&rootDescriptor
                                                          error:error] != nil;
  NSString *stagingName = [@".staging-" stringByAppendingString:projectId];
  struct stat rootProject = {};
  struct stat suppliedProject = {};
  BOOL bound = rootResolved && rootDescriptor >= 0 &&
      fstatat(rootDescriptor, stagingName.fileSystemRepresentation,
              &rootProject, AT_SYMLINK_NOFOLLOW) == 0 &&
      fstat(projectDescriptor, &suppliedProject) == 0 &&
      S_ISDIR(rootProject.st_mode) &&
      DSHSameNode(rootProject, suppliedProject);
  if (rootDescriptor >= 0) close(rootDescriptor);
  if (!bound) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return NO;
  }
  return DSHWriteProjectMetadataRecord(record, projectDescriptor, error);
}

static BOOL DSHWriteProjectMetadataRecord(NSDictionary *record,
                                          int projectDescriptor,
                                          NSError **error) {
  if (!DSHValidStoredMetadataRecord(record) || projectDescriptor < 0) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorMetadataInvalid);
    return NO;
  }
  NSData *data = [NSJSONSerialization dataWithJSONObject:record
                                                  options:NSJSONWritingSortedKeys
                                                    error:nil];
  if (data == nil || data.length > DSHProjectMetadataMaxBytes) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorMetadataInvalid);
    return NO;
  }
  struct stat projectMetadata = {};
  struct stat existing = {};
  BOOL projectSafe = fstat(projectDescriptor, &projectMetadata) == 0 &&
                     S_ISDIR(projectMetadata.st_mode);
  errno = 0;
  BOOL exists = fstatat(projectDescriptor, "project.json", &existing,
                        AT_SYMLINK_NOFOLLOW) == 0;
  BOOL existingSafe = !exists
      ? errno == ENOENT
      : S_ISREG(existing.st_mode) && existing.st_nlink == 1 &&
            existing.st_dev == projectMetadata.st_dev;
  if (!projectSafe || !existingSafe) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return NO;
  }
  NSString *temporaryName = [@".project-json-"
      stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
  int descriptor = openat(projectDescriptor, temporaryName.fileSystemRepresentation,
                          O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC |
                              O_NOFOLLOW,
                          0600);
  BOOL success = descriptor >= 0 && DSHWriteAllBytes(descriptor, data) &&
                 fchmod(descriptor, 0600) == 0 && fsync(descriptor) == 0;
  if (descriptor >= 0) close(descriptor);
  if (success) {
    success = renameat(projectDescriptor, temporaryName.fileSystemRepresentation,
                       projectDescriptor, "project.json") == 0 &&
              fsync(projectDescriptor) == 0;
  }
  if (!success) {
    unlinkat(projectDescriptor, temporaryName.fileSystemRepresentation, 0);
    DSHSetAccessError(error, DSHLocalProjectAccessErrorStorageUnavailable);
    return NO;
  }
  struct stat published = {};
  success = fstatat(projectDescriptor, "project.json", &published,
                    AT_SYMLINK_NOFOLLOW) == 0 &&
            S_ISREG(published.st_mode) && published.st_nlink == 1 &&
            published.st_dev == projectMetadata.st_dev &&
            published.st_size == (off_t)data.length &&
            (published.st_mode & 0777) == 0600;
  if (!success) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
  }
  return success;
}

- (DSHLocalProjectLease *)leaseWorkspaceRootRef:(NSDictionary *)rootRef
                                  workspaceLease:(DSHLocalWorkspaceLease *)workspaceLease
                                             mode:(DSHLocalProjectAccessMode)mode
                                  includeMetadata:(BOOL)includeMetadata
                                          timeout:(NSTimeInterval)timeout
                                            error:(NSError **)error {
  return [self leaseWorkspaceRootRef:rootRef
                       workspaceLease:workspaceLease
                     authorityAccess:self.workspaceAccess
                    workspaceBinding:nil
                                mode:mode
                     includeMetadata:includeMetadata
                             timeout:timeout
                               error:error];
}

- (DSHLocalProjectLease *)leaseWorkspaceRootRef:(NSDictionary *)rootRef
                                  workspaceLease:(DSHLocalWorkspaceLease *)workspaceLease
                               workspaceBinding:(NSDictionary *)workspaceBinding
                                             mode:(DSHLocalProjectAccessMode)mode
                                  includeMetadata:(BOOL)includeMetadata
                                          timeout:(NSTimeInterval)timeout
                                            error:(NSError **)error {
  return [self leaseWorkspaceRootRef:rootRef
                       workspaceLease:workspaceLease
                     authorityAccess:self.workspaceAccess
                    workspaceBinding:workspaceBinding
                                mode:mode
                     includeMetadata:includeMetadata
                             timeout:timeout
                               error:error];
}

- (DSHLocalProjectLease *)leaseWorkspaceRootRef:(NSDictionary *)rootRef
                                  workspaceLease:(DSHLocalWorkspaceLease *)workspaceLease
                                authorityAccess:(DSHLocalWorkspaceAccess *)authorityAccess
                               workspaceBinding:(NSDictionary *)workspaceBinding
                                             mode:(DSHLocalProjectAccessMode)mode
                                  includeMetadata:(BOOL)includeMetadata
                                          timeout:(NSTimeInterval)timeout
                                            error:(NSError **)error {
  NSUInteger revision = 0;
  if (!DSHLocalProjectRootRefIsValid(rootRef, YES, &revision) ||
      workspaceLease == nil || workspaceLease.rootDescriptor < 0 ||
      authorityAccess == nil ||
      (mode != DSHLocalProjectAccessModeRead &&
       mode != DSHLocalProjectAccessModeWrite) ||
      !isfinite(timeout)) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorInvalidIdentifier);
    return nil;
  }

  NSDictionary *canonicalRoot = DSHLocalProjectCanonicalRootRef(rootRef);
  if (canonicalRoot == nil) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorInvalidIdentifier);
    return nil;
  }
  NSString *workspaceId = canonicalRoot[@"workspace_id"];
  NSString *projectId = canonicalRoot[@"project_id"];
  if (![workspaceLease.workspaceId isEqual:workspaceId] ||
      workspaceLease.bindingRevision != revision ||
      !workspaceLease.supportsGit) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorRepositoryUnavailable);
    return nil;
  }

  DSHLocalProjectLockToken *projectLock = [[DSHLocalProjectLockToken alloc]
      initWithLock:DSHLockForProjectId(projectId)
         projectId:projectId
              mode:mode
           timeout:timeout];
  if (!projectLock.acquired) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorLockTimeout);
    return nil;
  }

  NSError *authorityError = nil;
  NSString *rootFingerprint = nil;
  NSDictionary *registry = [authorityAccess loadRegistry:&authorityError
                                                   digest:nil];
  NSDictionary *record = registry == nil
      ? nil : [authorityAccess recordInRegistry:registry
                                     workspaceId:workspaceId];
  NSDictionary *authority = record == nil
      ? nil : [authorityAccess loadAuthorityForRecord:record
                                                 error:&authorityError];
  if (authority != nil &&
      [authority[@"workspace_id"] isEqual:workspaceId] &&
      [authority[@"binding_revision"] isEqual:@(revision)] &&
      DSHLocalProjectCanonicalDigest(authority[@"root_fingerprint_sha256"])) {
    rootFingerprint = [authority[@"root_fingerprint_sha256"] copy];
  }
  if (rootFingerprint == nil) {
    if (error != nil) *error = authorityError ?: DSHAccessError(
        DSHLocalProjectAccessErrorUnsafeStorage);
    return nil;
  }
  // Bind the descriptor supplied by DSHLocalWorkspaceLease to the same
  // device/inode recorded by the workspace authority. Matching only the
  // lease's path would allow a same-ID lease from another native access
  // instance to cross the workspace boundary.
  unsigned long long authorityDevice = 0;
  unsigned long long authorityInode = 0;
  if (!DSHLocalProjectAccessParseCanonicalUInt64(authority[@"device_id"],
                                                 &authorityDevice) ||
      !DSHLocalProjectAccessParseCanonicalUInt64(authority[@"inode_id"],
                                                 &authorityInode)) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return nil;
  }
  NSURL *workspaceRootURL =
      DSHLocalProjectWorkspaceRootURL(authorityAccess, record);
  NSString *expectedRootPath = workspaceRootURL.path.stringByStandardizingPath;

  if (self.hook != nil) self.hook(@"before_workspace_root_open");
  struct stat rootMetadata = {};
  BOOL rootValid = fstat(workspaceLease.rootDescriptor, &rootMetadata) == 0 &&
      S_ISDIR(rootMetadata.st_mode) && !S_ISLNK(rootMetadata.st_mode) &&
      (unsigned long long)rootMetadata.st_dev == authorityDevice &&
      (unsigned long long)rootMetadata.st_ino == authorityInode;
  NSString *rootPath = rootValid && expectedRootPath.length > 0
      ? expectedRootPath : nil;
  struct stat rootPathMetadata = {};
  rootValid = rootValid && rootPath != nil &&
      lstat(rootPath.fileSystemRepresentation, &rootPathMetadata) == 0 &&
      DSHLocalProjectSameStat(rootMetadata, rootPathMetadata);
  if (!rootValid) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return nil;
  }

  // V2 accepts only the approved split topology: the Files-visible workspace
  // is the worktree and the private binding supplies a separate gitdir. A
  // `.git` entry in the visible root, or a `repo` fixture child, is never an
  // authority for this path (legacy embedded repositories stay on the
  // explicit project-id adapter).
  NSError *bindingError = nil;
  NSDictionary *binding = workspaceBinding ?: [self workspaceBindingForRootRef:
      canonicalRoot rootFingerprintSHA256:rootFingerprint error:&bindingError];
  if (binding == nil) {
    if (error != nil) *error = bindingError ?: DSHAccessError(
        DSHLocalProjectAccessErrorRepositoryUnavailable);
    return nil;
  }
  NSString *bindingDigest = DSHLocalProjectBindingDigest(binding);
  if (!DSHLocalProjectCanonicalDigest(bindingDigest)) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorMetadataInvalid);
    return nil;
  }
  struct stat visibleGitProbe = {};
  if (fstatat(workspaceLease.rootDescriptor, ".git", &visibleGitProbe,
              AT_SYMLINK_NOFOLLOW) == 0) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return nil;
  }
  if (errno != ENOENT) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return nil;
  }
  int projectDescriptor = dup(workspaceLease.rootDescriptor);
  int repositoryDescriptor = dup(workspaceLease.rootDescriptor);
  struct stat projectMetadata = rootMetadata;
  struct stat repositoryMetadata = rootMetadata;
  if (projectDescriptor < 0 || repositoryDescriptor < 0) {
    if (repositoryDescriptor >= 0) close(repositoryDescriptor);
    if (projectDescriptor >= 0) close(projectDescriptor);
    DSHSetAccessError(error, DSHLocalProjectAccessErrorRepositoryUnavailable);
    return nil;
  }
  if (self.hook != nil) self.hook(@"after_workspace_project_open");
  struct stat rootPathAfterProject = {};
  if (lstat(rootPath.fileSystemRepresentation, &rootPathAfterProject) != 0 ||
      !DSHLocalProjectSameStat(rootMetadata, rootPathAfterProject)) {
    close(repositoryDescriptor);
    close(projectDescriptor);
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return nil;
  }
  visibleGitProbe = {};
  if (fstatat(workspaceLease.rootDescriptor, ".git", &visibleGitProbe,
             AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT) {
    close(repositoryDescriptor);
    close(projectDescriptor);
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return nil;
  }

  if (self.hook != nil) self.hook(@"before_workspace_git_open");
  NSURL *gitDirectoryURL = binding[@"git_directory_url"];
  NSString *gitDirectoryPath = gitDirectoryURL.path.stringByStandardizingPath;
  NSString *worktreePath = rootPath.stringByStandardizingPath;
  NSString *privateRootPath =
      authorityAccess.privateRootURL.path.stringByStandardizingPath;
  if (gitDirectoryPath.length == 0 || worktreePath.length == 0 ||
      privateRootPath.length == 0 ||
      ![gitDirectoryPath hasPrefix:
          [privateRootPath stringByAppendingString:@"/"]] ||
      [gitDirectoryPath isEqual:worktreePath] ||
      [gitDirectoryPath hasPrefix:[worktreePath stringByAppendingString:@"/"]]) {
    close(repositoryDescriptor);
    close(projectDescriptor);
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return nil;
  }
  int gitDescriptor = DSHOpenAnchoredAbsoluteDirectory(
      gitDirectoryURL, self.hook, error);
  struct stat gitMetadata = {};
  BOOL gitValid = gitDescriptor >= 0 && fstat(gitDescriptor, &gitMetadata) == 0 &&
      S_ISDIR(gitMetadata.st_mode) && !S_ISLNK(gitMetadata.st_mode);
  if (!gitValid) {
    if (gitDescriptor >= 0) close(gitDescriptor);
    close(repositoryDescriptor);
    close(projectDescriptor);
    DSHSetAccessError(error, DSHLocalProjectAccessErrorRepositoryUnavailable);
    return nil;
  }
  if (self.hook != nil) self.hook(@"after_workspace_git_open");
  struct stat rootPathAfterGit = {};
  if (lstat(rootPath.fileSystemRepresentation, &rootPathAfterGit) != 0 ||
      !DSHLocalProjectSameStat(rootMetadata, rootPathAfterGit)) {
    close(gitDescriptor);
    close(repositoryDescriptor);
    close(projectDescriptor);
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return nil;
  }
  struct stat gitPathMetadata = {};
  gitValid = lstat(gitDirectoryURL.fileSystemRepresentation,
                   &gitPathMetadata) == 0 &&
      DSHLocalProjectSameStat(gitMetadata, gitPathMetadata);
  if (!gitValid) {
    close(gitDescriptor);
    close(repositoryDescriptor);
    close(projectDescriptor);
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return nil;
  }
  struct stat objectsMetadata = {};
  int objectsDescriptor = openat(gitDescriptor, "objects",
                                 O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  BOOL objectsValid = objectsDescriptor >= 0 &&
      fstat(objectsDescriptor, &objectsMetadata) == 0 &&
      S_ISDIR(objectsMetadata.st_mode) && !S_ISLNK(objectsMetadata.st_mode) &&
      DSHForbiddenGitIndirectionAbsent(gitDescriptor, objectsDescriptor);
  struct stat objectsPathMetadata = {};
  objectsValid = objectsValid &&
      fstatat(gitDescriptor, "objects", &objectsPathMetadata,
              AT_SYMLINK_NOFOLLOW) == 0 &&
      DSHLocalProjectSameStat(objectsMetadata, objectsPathMetadata);
  if (!objectsValid) {
    if (objectsDescriptor >= 0) close(objectsDescriptor);
    close(gitDescriptor);
    close(repositoryDescriptor);
    close(projectDescriptor);
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return nil;
  }
  if (self.hook != nil) self.hook(@"after_workspace_objects_open");

  struct stat rootAfter = {};
  BOOL rootStillSame = fstat(workspaceLease.rootDescriptor, &rootAfter) == 0 &&
      DSHLocalProjectSameStat(rootMetadata, rootAfter);
  objectsPathMetadata = {};
  rootStillSame = rootStillSame &&
      fstatat(gitDescriptor, "objects", &objectsPathMetadata,
              AT_SYMLINK_NOFOLLOW) == 0 &&
      DSHLocalProjectSameStat(objectsMetadata, objectsPathMetadata);
  if (!rootStillSame) {
    close(objectsDescriptor);
    close(gitDescriptor);
    close(repositoryDescriptor);
    close(projectDescriptor);
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return nil;
  }

  NSString *repositoryPath = rootPath;
  NSString *gitPath = DSHLocalProjectDescriptorPath(gitDescriptor);
  if (repositoryPath == nil || gitPath == nil) {
    close(objectsDescriptor);
    close(gitDescriptor);
    close(repositoryDescriptor);
    close(projectDescriptor);
    DSHSetAccessError(error, DSHLocalProjectAccessErrorRepositoryUnavailable);
    return nil;
  }
  git_repository *repository = nullptr;
  int openResult = git_repository_open_ext(
      &repository, gitPath.fileSystemRepresentation,
      GIT_REPOSITORY_OPEN_NO_SEARCH | GIT_REPOSITORY_OPEN_NO_DOTGIT |
          GIT_REPOSITORY_OPEN_BARE,
      nullptr);
  BOOL splitConfigured = openResult == 0 && repository != nullptr &&
      git_repository_is_bare(repository) &&
      git_repository_set_workdir(repository, repositoryPath.fileSystemRepresentation,
                                  0) == 0;
  const char *workdir = splitConfigured && repository != nullptr
      ? git_repository_workdir(repository) : nullptr;
  NSString *actualWorkdir = workdir == nullptr ? nil :
      [[NSFileManager defaultManager]
          stringWithFileSystemRepresentation:workdir length:strlen(workdir)];
  NSString *expectedWorkdir = [repositoryPath stringByStandardizingPath];
  BOOL repositoryValid = openResult == 0 && repository != nullptr &&
      splitConfigured && !git_repository_is_bare(repository) && actualWorkdir != nil &&
      [actualWorkdir.stringByStandardizingPath isEqual:expectedWorkdir];
  if (repositoryValid) {
    const char *actualGit = git_repository_path(repository);
    NSString *actualGitPath = actualGit == nullptr ? nil :
        [[NSFileManager defaultManager]
            stringWithFileSystemRepresentation:actualGit length:strlen(actualGit)];
    repositoryValid = actualGitPath != nil &&
        [actualGitPath.stringByStandardizingPath isEqual:
             [gitPath stringByStandardizingPath]];
  }
  if (repositoryValid) {
    const char *actualCommon = git_repository_commondir(repository);
    NSString *actualCommonPath = actualCommon == nullptr ? nil :
        [[NSFileManager defaultManager]
            stringWithFileSystemRepresentation:actualCommon
                                         length:strlen(actualCommon)];
    repositoryValid = actualCommonPath != nil &&
        [actualCommonPath.stringByStandardizingPath isEqual:
             [gitPath stringByStandardizingPath]];
  }
  if (!repositoryValid) {
    if (repository != nullptr) git_repository_free(repository);
    close(objectsDescriptor);
    close(gitDescriptor);
    close(repositoryDescriptor);
    close(projectDescriptor);
    DSHSetAccessError(error, DSHLocalProjectAccessErrorRepositoryUnavailable);
    return nil;
  }

  struct stat repositoryAfter = {};
  struct stat gitAfter = {};
  struct stat objectsAfter = {};
  struct stat rootPathAfterOpen = {};
  struct stat visibleGitAfterOpen = {};
  BOOL descriptorsStable = fstat(repositoryDescriptor, &repositoryAfter) == 0 &&
      fstat(gitDescriptor, &gitAfter) == 0 &&
      fstat(objectsDescriptor, &objectsAfter) == 0 &&
      lstat(rootPath.fileSystemRepresentation, &rootPathAfterOpen) == 0 &&
      DSHLocalProjectSameStat(rootMetadata, rootPathAfterOpen) &&
      DSHLocalProjectSameStat(repositoryMetadata, repositoryAfter) &&
      DSHLocalProjectSameStat(gitMetadata, gitAfter) &&
      DSHLocalProjectSameStat(objectsMetadata, objectsAfter) &&
      lstat(gitDirectoryURL.fileSystemRepresentation, &gitPathMetadata) == 0 &&
      DSHLocalProjectSameStat(gitAfter, gitPathMetadata) &&
      fstatat(gitDescriptor, "objects", &objectsPathMetadata,
              AT_SYMLINK_NOFOLLOW) == 0 &&
      DSHLocalProjectSameStat(objectsAfter, objectsPathMetadata) &&
      fstatat(workspaceLease.rootDescriptor, ".git", &visibleGitAfterOpen,
              AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT;
  if (!descriptorsStable) {
    git_repository_free(repository);
    close(objectsDescriptor);
    close(gitDescriptor);
    close(repositoryDescriptor);
    close(projectDescriptor);
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return nil;
  }

  NSDictionary *metadata = nil;
  if (includeMetadata) {
    NSString *name = binding[@"display_name"];
    NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding
                              allowLossyConversion:NO];
    if (name.length == 0 || nameData == nil || nameData.length > 120 ||
        DSHHasControlCharacter(name) || [name containsString:@"/"] ||
        [name containsString:@"\\"] || [name isEqual:@"."] ||
        [name isEqual:@".."]) {
      name = projectId;
    }
    metadata = @{
      @"schema_version" : @2,
      @"id" : projectId,
      @"name" : name,
      @"workspace_id" : workspaceId,
      @"binding_revision" : @(revision),
    };
  }
  if (rootFingerprint == nil) {
    git_repository_free(repository);
    close(objectsDescriptor);
    close(gitDescriptor);
    close(repositoryDescriptor);
    close(projectDescriptor);
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return nil;
  }

  DSHLocalProjectLease *lease = [[DSHLocalProjectLease alloc] init];
  lease.projectId = projectId;
  lease.workspaceId = workspaceId;
  lease.workspaceBindingRevision = revision;
  lease.rootFingerprintSHA256 = rootFingerprint;
  lease.workspaceRootRef = canonicalRoot;
  lease.workspaceLease = workspaceLease;
  lease.workspaceAccess = authorityAccess;
  lease.workspaceBinding = binding;
  lease.workspaceBindingWasInjected = workspaceBinding != nil;
  lease.workspaceBindingDigest = bindingDigest;
  lease.gitTopology = binding[@"git_topology"];
  lease.workspaceGitDirectoryURL = gitDirectoryURL;
  lease.workspaceRootDescriptor = dup(workspaceLease.rootDescriptor);
  lease.workspaceRootDevice = rootMetadata.st_dev;
  lease.workspaceRootInode = rootMetadata.st_ino;
  lease.projectDirectoryURL = [NSURL fileURLWithPath:repositoryPath
                                         isDirectory:YES];
  lease.repositoryURL = lease.projectDirectoryURL;
  lease.metadata = metadata;
  lease.workspaceProjectMetadataDigest =
      DSHWorkspaceSHA256Hex(DSHWorkspaceCanonicalJSONData(
          metadata ?: @{}, nil));
  lease.projectsRootDescriptor = dup(workspaceLease.rootDescriptor);
  lease.projectDescriptor = projectDescriptor;
  lease.repositoryDescriptor = repositoryDescriptor;
  lease.gitDescriptor = gitDescriptor;
  lease.objectsDescriptor = objectsDescriptor;
  lease.projectsRootDevice = rootMetadata.st_dev;
  lease.projectsRootInode = rootMetadata.st_ino;
  lease.projectDevice = projectMetadata.st_dev;
  lease.projectInode = projectMetadata.st_ino;
  lease.repositoryDevice = repositoryMetadata.st_dev;
  lease.repositoryInode = repositoryMetadata.st_ino;
  lease.gitDevice = gitMetadata.st_dev;
  lease.gitInode = gitMetadata.st_ino;
  lease.objectsDevice = objectsMetadata.st_dev;
  lease.objectsInode = objectsMetadata.st_ino;
  lease.repository = repository;
  lease.accessMode = mode;
  lease.lockToken = projectLock;
  // V2 leases are rooted directly at the authoritative workspace root.  The
  // private split git directory is tracked separately above; there is no
  // project/repository path component to persist as a fallback identity.
  lease.workspaceProjectComponent = @".";
  lease.workspaceGitComponent = nil;
  lease.workspacePath = repositoryPath;
  if (![self validateWorkspaceLeaseIdentity:lease
                                     rootRef:canonicalRoot
                                       error:error]) {
    return nil;
  }
  return lease;
}

- (DSHLocalProjectLease *)leaseWorkspaceRootRef:(NSDictionary *)rootRef
                                             mode:(DSHLocalProjectAccessMode)mode
                                  includeMetadata:(BOOL)includeMetadata
                                          timeout:(NSTimeInterval)timeout
                                            error:(NSError **)error {
  return [self leaseWorkspaceRootRef:rootRef
                      workspaceAccess:self.workspaceAccess
                                 mode:mode
                      includeMetadata:includeMetadata
                              timeout:timeout
                                error:error];
}

- (DSHLocalProjectLease *)leaseWorkspaceRootRef:(NSDictionary *)rootRef
                                  workspaceAccess:(DSHLocalWorkspaceAccess *)workspaceAccess
                                             mode:(DSHLocalProjectAccessMode)mode
                                  includeMetadata:(BOOL)includeMetadata
                                          timeout:(NSTimeInterval)timeout
                                            error:(NSError **)error {
  NSUInteger revision = 0;
  if (!DSHLocalProjectRootRefIsValid(rootRef, YES, &revision) ||
      workspaceAccess == nil) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorInvalidIdentifier);
    return nil;
  }
  NSError *workspaceError = nil;
  DSHLocalWorkspaceLease *workspaceLease = [workspaceAccess
      leaseWorkspaceId:rootRef[@"workspace_id"]
      expectedBindingRevision:revision
      requiredCapabilities:[NSSet setWithObjects:@"read", @"git",
                                      @"project_context", nil]
      error:&workspaceError];
  if (workspaceLease == nil) {
    if (error != nil) *error = workspaceError ?: DSHAccessError(
        DSHLocalProjectAccessErrorRepositoryUnavailable);
    return nil;
  }
  return [self leaseWorkspaceRootRef:rootRef
                       workspaceLease:workspaceLease
                     authorityAccess:workspaceAccess
                    workspaceBinding:nil
                                mode:mode
                     includeMetadata:includeMetadata
                             timeout:timeout
                               error:error];
}

- (BOOL)validateWorkspaceLeaseIdentity:(DSHLocalProjectLease *)lease
                                rootRef:(NSDictionary *)rootRef
                                  error:(NSError **)error {
  NSUInteger revision = 0;
  NSDictionary *canonicalRoot = DSHLocalProjectCanonicalRootRef(rootRef);
  if (lease == nil || lease.workspaceLease == nil || canonicalRoot == nil ||
      !DSHLocalProjectRootRefIsValid(canonicalRoot, YES, &revision) ||
      ![lease.workspaceRootRef isEqual:canonicalRoot] ||
      ![lease.workspaceId isEqual:canonicalRoot[@"workspace_id"]] ||
      lease.workspaceBindingRevision != revision ||
      ![lease.projectId isEqual:canonicalRoot[@"project_id"]] ||
      ![lease.gitTopology isEqual:@"private_split_gitdir"] ||
      !DSHLocalProjectCanonicalDigest(lease.workspaceBindingDigest) ||
      lease.workspaceRootDescriptor < 0 || lease.projectDescriptor < 0 ||
      lease.repositoryDescriptor < 0 || lease.gitDescriptor < 0 ||
      lease.objectsDescriptor < 0 || lease.repository == nullptr ||
      lease.workspaceLease.rootDescriptor < 0) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return NO;
  }
  if (![lease.workspaceLease.workspaceId isEqual:lease.workspaceId] ||
      lease.workspaceLease.bindingRevision != lease.workspaceBindingRevision ||
      !lease.workspaceLease.supportsGit) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorRepositoryUnavailable);
    return NO;
  }
  if (lease.workspaceAccess == nil) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return NO;
  }
  NSError *authorityError = nil;
  NSDictionary *registry = [lease.workspaceAccess loadRegistry:&authorityError
                                                          digest:nil];
  NSDictionary *record = registry == nil
      ? nil : [lease.workspaceAccess recordInRegistry:registry
                                          workspaceId:lease.workspaceId];
  NSDictionary *authority = record == nil
      ? nil : [lease.workspaceAccess loadAuthorityForRecord:record
                                                       error:&authorityError];
  if (authority == nil ||
      ![authority[@"workspace_id"] isEqual:lease.workspaceId] ||
      ![authority[@"binding_revision"] isEqual:@(lease.workspaceBindingRevision)] ||
      ![authority[@"root_fingerprint_sha256"]
          isEqual:lease.rootFingerprintSHA256]) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return NO;
  }
  unsigned long long authorityDevice = 0;
  unsigned long long authorityInode = 0;
  if (!DSHLocalProjectAccessParseCanonicalUInt64(authority[@"device_id"],
                                                 &authorityDevice) ||
      !DSHLocalProjectAccessParseCanonicalUInt64(authority[@"inode_id"],
                                                 &authorityInode)) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return NO;
  }
  NSURL *workspaceRootURL =
      DSHLocalProjectWorkspaceRootURL(lease.workspaceAccess, record);
  NSString *expectedRootPath = workspaceRootURL.path.stringByStandardizingPath;
  NSError *bindingError = nil;
  // Explicit bindings exist only for the pre-publication attach staging
  // lease. Production leases must re-open the native workspace/project
  // relation on every identity validation; trusting the binding cached at
  // lease construction would miss a relation change during a Files block.
  NSDictionary *currentBinding = lease.workspaceBindingWasInjected
      ? lease.workspaceBinding
      : [self workspaceBindingForRootRef:canonicalRoot
                    rootFingerprintSHA256:lease.rootFingerprintSHA256
                                   error:&bindingError];
  if (currentBinding == nil ||
      ![DSHLocalProjectBindingDigest(currentBinding)
          isEqual:lease.workspaceBindingDigest] ||
      ![currentBinding[@"git_directory_url"]
          isEqual:lease.workspaceGitDirectoryURL]) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorMetadataInvalid);
    return NO;
  }
  NSString *privateRootPath =
      lease.workspaceAccess.privateRootURL.path.stringByStandardizingPath;
  NSString *currentGitPath =
      lease.workspaceGitDirectoryURL.path.stringByStandardizingPath;
  if (privateRootPath.length == 0 || currentGitPath.length == 0 ||
      ![currentGitPath hasPrefix:
          [privateRootPath stringByAppendingString:@"/"]]) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return NO;
  }
  if (self.hook != nil) self.hook(@"before_workspace_identity_recheck");

  struct stat root = {};
  struct stat retainedRoot = {};
  struct stat project = {};
  struct stat repository = {};
  struct stat git = {};
  struct stat objects = {};
  BOOL valid = fstat(lease.workspaceLease.rootDescriptor, &root) == 0 &&
      fstat(lease.workspaceRootDescriptor, &retainedRoot) == 0 &&
      fstat(lease.projectDescriptor, &project) == 0 &&
      fstat(lease.repositoryDescriptor, &repository) == 0 &&
      fstat(lease.gitDescriptor, &git) == 0 &&
      fstat(lease.objectsDescriptor, &objects) == 0 &&
      DSHLocalProjectSameStat(root, retainedRoot) &&
      root.st_dev == lease.workspaceRootDevice &&
      root.st_ino == lease.workspaceRootInode &&
      (unsigned long long)root.st_dev == authorityDevice &&
      (unsigned long long)root.st_ino == authorityInode &&
      project.st_dev == lease.projectDevice &&
      project.st_ino == lease.projectInode &&
      repository.st_dev == lease.repositoryDevice &&
      repository.st_ino == lease.repositoryInode &&
      git.st_dev == lease.gitDevice && git.st_ino == lease.gitInode &&
      objects.st_dev == lease.objectsDevice &&
      objects.st_ino == lease.objectsInode && S_ISDIR(root.st_mode) &&
      S_ISDIR(project.st_mode) && S_ISDIR(repository.st_mode) &&
      S_ISDIR(git.st_mode) && S_ISDIR(objects.st_mode) &&
      DSHForbiddenGitIndirectionAbsent(lease.gitDescriptor,
                                       lease.objectsDescriptor);
  NSString *rootPath = expectedRootPath.length > 0 ? expectedRootPath : nil;
  struct stat pathRoot = {};
  valid = valid && rootPath != nil &&
      lstat(rootPath.fileSystemRepresentation, &pathRoot) == 0 &&
      DSHLocalProjectSameStat(root, pathRoot);
  struct stat pathGit = {};
  struct stat pathObjects = {};
  valid = valid && lease.workspaceGitDirectoryURL != nil &&
      lstat(lease.workspaceGitDirectoryURL.fileSystemRepresentation, &pathGit) == 0 &&
      DSHLocalProjectSameStat(git, pathGit) &&
      fstatat(lease.gitDescriptor, "objects", &pathObjects,
              AT_SYMLINK_NOFOLLOW) == 0 &&
      DSHLocalProjectSameStat(objects, pathObjects);
  struct stat visibleGit = {};
  valid = valid && fstatat(lease.workspaceLease.rootDescriptor, ".git",
                           &visibleGit, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT;
  if (!valid) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return NO;
  }

  if (!DSHLocalProjectCanonicalDigest(lease.rootFingerprintSHA256)) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorUnsafeStorage);
    return NO;
  }
  return YES;
}

- (DSHLocalProjectLeaseSet *)
    leaseWorkspaceReadPaths:(NSArray<NSString *> *)readPaths
                  writePaths:(NSArray<NSString *> *)writePaths
                     timeout:(NSTimeInterval)timeout
                       error:(NSError **)error {
  if (![readPaths isKindOfClass:NSArray.class] ||
      ![writePaths isKindOfClass:NSArray.class] || !isfinite(timeout)) {
    DSHSetAccessError(error, DSHLocalProjectAccessErrorInvalidIdentifier);
    return nil;
  }
  NSMutableDictionary<NSString *, NSNumber *> *modes =
      [NSMutableDictionary dictionary];
  for (NSUInteger kind = 0; kind < 2; kind++) {
    NSArray<NSString *> *paths = kind == 0 ? readPaths : writePaths;
    for (id path in paths) {
      NSError *pathError = nil;
      NSString *projectId =
          [DSHLocalProjectAccess projectIdForWorkspacePath:path error:&pathError];
      if (projectId == nil && pathError != nil) {
        if (error != nil) *error = pathError;
        return nil;
      }
      if (projectId != nil) {
        DSHLocalProjectAccessMode mode = kind == 0
            ? DSHLocalProjectAccessModeRead
            : DSHLocalProjectAccessModeWrite;
        if (modes[projectId] == nil || mode == DSHLocalProjectAccessModeWrite) {
          modes[projectId] = @(mode);
        }
      }
    }
  }
  NSArray<NSString *> *projectIds =
      [modes.allKeys sortedArrayUsingSelector:@selector(compare:)];
  NSMutableDictionary<NSString *, DSHLocalProjectLease *> *leases =
      [NSMutableDictionary dictionary];
  CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
  for (NSString *projectId in projectIds) {
    NSTimeInterval remaining = timeout;
    if (timeout >= 0) {
      remaining = MAX(0, timeout - (CFAbsoluteTimeGetCurrent() - started));
    }
    DSHLocalProjectLease *lease = [self
        leaseProjectId:projectId
                  mode:(DSHLocalProjectAccessMode)modes[projectId].integerValue
       includeMetadata:NO
               timeout:remaining
                 error:error];
    if (lease == nil) return nil;
    leases[projectId] = lease;
  }
  DSHLocalProjectLeaseSet *set = [[DSHLocalProjectLeaseSet alloc] init];
  set.leases = leases;
  return set;
}

@end
