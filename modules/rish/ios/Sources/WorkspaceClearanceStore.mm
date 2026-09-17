#import "WorkspaceClearanceStore.h"
#import "LocalWorkspaceAccess.h"

#import "DSHWorkspaceCanonical.h"

#include "rish_agent_core.h"

#import <TargetConditionals.h>
#import <objc/runtime.h>

#include <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <dirent.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

NSErrorDomain const DSHWorkspaceClearanceStoreErrorDomain =
    @"dev.zseven.rish.workspace-clearance-store";

NSString *const DSHWorkspaceClearanceStoreErrorInvalidCode =
    @"E_WORKSPACE_INVALID";
NSString *const DSHWorkspaceClearanceStoreErrorCorruptCode =
    @"E_WORKSPACE_PERSISTENCE";
NSString *const DSHWorkspaceClearanceStoreErrorStorageCode =
    @"E_WORKSPACE_PERSISTENCE";
NSString *const DSHWorkspaceClearanceStoreErrorConflictCode =
    @"E_WORKSPACE_CONFLICT";
NSString *const DSHWorkspaceClearanceStoreErrorNotFoundCode =
    @"E_WORKSPACE_NOT_FOUND";
NSString *const DSHWorkspaceClearanceStoreErrorBusyCode =
    @"E_WORKSPACE_BUSY";
NSString *const DSHWorkspaceClearanceStoreErrorBoundsCode =
    @"E_WORKSPACE_PERSISTENCE";

static NSString *const DSHWorkspaceClearanceFilename =
    @".workspace-clearance-v1.json";
static NSString *const DSHWorkspaceClearanceTemporaryFilename =
    @".workspace-clearance-v1.json.tmp";
// SessionSnapshotStore uses this same lock file.  The coordinator serializes
// in-process work while this flock keeps a second native process from
// interleaving session and clearance writes.
static NSString *const DSHWorkspaceClearanceLockFilename =
    @".sessions.cas-lock";
static const NSUInteger DSHWorkspaceClearanceMaximumBytes = 512U * 1024U;
static const NSUInteger DSHWorkspaceClearanceMaximumReceipts = 2048U;
static const NSTimeInterval DSHWorkspaceClearanceTTL = 30.0 * 24.0 * 60.0 * 60.0;
static const unsigned long long DSHWorkspaceClearanceMaximumSafeInteger =
    9007199254740991ULL;

static NSLock *DSHWorkspaceClearanceCheckpointLock(void) {
  static NSLock *lock;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    lock = [[NSLock alloc] init];
  });
  return lock;
}

static NSMutableDictionary<NSString *, NSNumber *> *
DSHWorkspaceClearanceCheckpoints(void) {
  static NSMutableDictionary<NSString *, NSNumber *> *checkpoints;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    checkpoints = [NSMutableDictionary dictionary];
  });
  return checkpoints;
}

static NSString *DSHWorkspaceClearanceCheckpointKey(NSString *workspaceId,
                                                    NSUInteger revision) {
  return [NSString stringWithFormat:@"%@:%lu", workspaceId,
                                    (unsigned long)revision];
}

typedef NS_ENUM(NSInteger, DSHWorkspaceClearanceAtomicWriteResult) {
  DSHWorkspaceClearanceAtomicWriteCommitted = 0,
  DSHWorkspaceClearanceAtomicWriteNoEffect = 1,
  DSHWorkspaceClearanceAtomicWriteUnknown = 2,
};

static NSError *DSHWorkspaceClearanceError(
    DSHWorkspaceClearanceStoreErrorCode code) {
  NSString *publicCode = DSHWorkspaceClearanceStoreErrorStorageCode;
  switch (code) {
    case DSHWorkspaceClearanceStoreErrorInvalidArgument:
      publicCode = DSHWorkspaceClearanceStoreErrorInvalidCode;
      break;
    case DSHWorkspaceClearanceStoreErrorCorrupt:
      publicCode = DSHWorkspaceClearanceStoreErrorCorruptCode;
      break;
    case DSHWorkspaceClearanceStoreErrorStorage:
      publicCode = DSHWorkspaceClearanceStoreErrorStorageCode;
      break;
    case DSHWorkspaceClearanceStoreErrorConflict:
      publicCode = DSHWorkspaceClearanceStoreErrorConflictCode;
      break;
    case DSHWorkspaceClearanceStoreErrorNotFound:
      publicCode = DSHWorkspaceClearanceStoreErrorNotFoundCode;
      break;
    case DSHWorkspaceClearanceStoreErrorBusy:
      publicCode = DSHWorkspaceClearanceStoreErrorBusyCode;
      break;
    case DSHWorkspaceClearanceStoreErrorBounds:
      publicCode = DSHWorkspaceClearanceStoreErrorBoundsCode;
      break;
  }
  return [NSError errorWithDomain:DSHWorkspaceClearanceStoreErrorDomain
                             code:code
                         userInfo:@{
                           @"code" : publicCode,
                           NSLocalizedDescriptionKey : publicCode,
                         }];
}

static BOOL DSHWorkspaceClearanceSetError(
    NSError **error,
    DSHWorkspaceClearanceStoreErrorCode code) {
  if (error != nullptr) *error = DSHWorkspaceClearanceError(code);
  return NO;
}

static BOOL DSHWorkspaceClearanceFoundationObject(id value) {
  if (value == nil) return NO;
  const char *image = class_getImageName(object_getClass(value));
  if (image == nullptr) return NO;
  return strstr(image, "/Foundation.framework/") != nullptr ||
      strstr(image, "/CoreFoundation.framework/") != nullptr ||
      strstr(image, "/libobjc.A.dylib") != nullptr;
}

static BOOL DSHWorkspaceClearanceDictionary(id value) {
  return [value isKindOfClass:NSDictionary.class] &&
      DSHWorkspaceClearanceFoundationObject(value) && [value copy] == value;
}

static BOOL DSHWorkspaceClearanceArray(id value) {
  return [value isKindOfClass:NSArray.class] &&
      DSHWorkspaceClearanceFoundationObject(value) && [value copy] == value;
}

static BOOL DSHWorkspaceClearanceString(id value) {
  return [value isKindOfClass:NSString.class] &&
      DSHWorkspaceClearanceFoundationObject(value) && [value copy] == value;
}

static BOOL DSHWorkspaceClearanceNumber(id value) {
  return [value isKindOfClass:NSNumber.class] &&
      ![value isKindOfClass:NSDecimalNumber.class] &&
      DSHWorkspaceClearanceFoundationObject(value);
}

static BOOL DSHWorkspaceClearanceBoolean(id value) {
  return DSHWorkspaceClearanceNumber(value) &&
      CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL DSHWorkspaceClearanceSafeInteger(id value,
                                             BOOL allowZero) {
  if (!DSHWorkspaceClearanceNumber(value) ||
      DSHWorkspaceClearanceBoolean(value)) {
    return NO;
  }
  double number = [value doubleValue];
  return isfinite(number) && floor(number) == number && number >= 0.0 &&
      number <= (double)DSHWorkspaceClearanceMaximumSafeInteger &&
      !(number == 0.0 && signbit(number)) &&
      (allowZero || number != 0.0) &&
      [value unsignedLongLongValue] == (unsigned long long)number;
}

static BOOL DSHWorkspaceClearanceExactKeys(NSDictionary *value,
                                           NSArray<NSString *> *keys) {
  if (!DSHWorkspaceClearanceDictionary(value) || value.count != keys.count) {
    return NO;
  }
  NSSet *expected = [NSSet setWithArray:keys];
  for (id key in value) {
    if (!DSHWorkspaceClearanceString(key) ||
        ![expected containsObject:key]) {
      return NO;
    }
  }
  return YES;
}

static BOOL DSHWorkspaceClearanceUUID(id value) {
  if (!DSHWorkspaceClearanceString(value)) return NO;
  NSString *string = value;
  if (string.length != 36 ||
      ![string isEqualToString:string.lowercaseString]) return NO;
  NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:string];
  return uuid != nil && [uuid.UUIDString.lowercaseString isEqualToString:string];
}

static BOOL DSHWorkspaceClearanceDigest(id value) {
  if (!DSHWorkspaceClearanceString(value)) return NO;
  NSString *string = value;
  if (string.length != 64 ||
      ![string isEqualToString:string.lowercaseString]) return NO;
  NSCharacterSet *hex =
      [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
  return [string rangeOfCharacterFromSet:hex.invertedSet].location == NSNotFound;
}

static BOOL DSHWorkspaceClearanceTimestamp(id value) {
  if (!DSHWorkspaceClearanceString(value)) return NO;
  NSString *string = value;
  if (string.length != 24 || [string characterAtIndex:19] != '.' ||
      [string characterAtIndex:23] != 'Z' ||
      [string characterAtIndex:4] != '-' ||
      [string characterAtIndex:7] != '-' ||
      [string characterAtIndex:10] != 'T' ||
      [string characterAtIndex:13] != ':' ||
      [string characterAtIndex:16] != ':') {
    return NO;
  }
  NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
  formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                            NSISO8601DateFormatWithFractionalSeconds;
  formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
  NSDate *date = [formatter dateFromString:string];
  return date != nil && [[formatter stringFromDate:date] isEqualToString:string];
}

static NSString *DSHWorkspaceClearanceTimestampForDate(NSDate *date) {
  if (![date isKindOfClass:NSDate.class]) return nil;
  NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
  formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                            NSISO8601DateFormatWithFractionalSeconds;
  formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
  NSString *result = [formatter stringFromDate:date];
  return DSHWorkspaceClearanceTimestamp(result) ? result : nil;
}

static NSDate *DSHWorkspaceClearanceDateFromTimestamp(NSString *value) {
  if (!DSHWorkspaceClearanceTimestamp(value)) return nil;
  NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
  formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                            NSISO8601DateFormatWithFractionalSeconds;
  formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
  return [formatter dateFromString:value];
}

// What a clearance operation and its receipt look like lives in the shared
// core (modules/rish/core, `rish_agent_workspace_clearance_reduce`). The
// store's bounds are the workspace receipt store's, and are now stated once
// there rather than separately here.
static NSDictionary *DSHWorkspaceClearanceReduce(NSString *op,
                                                 NSDictionary *fields) {
  NSMutableDictionary *envelope = [fields mutableCopy];
  envelope[@"op"] = op;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:envelope options:0
                                                    error:nil];
  char *raw = bytes == nil ? NULL : rish_agent_workspace_clearance_reduce(
      (const char *)bytes.bytes, bytes.length);
  if (raw == NULL) return nil;
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0
                                                error:nil];
  return [reply isKindOfClass:NSDictionary.class] &&
      [reply[@"ok"] isEqual:@YES] ? reply : nil;
}

static BOOL DSHWorkspaceClearanceCanonicalOperationFields(
    NSDictionary *operation) {
  return [DSHWorkspaceClearanceReduce(@"operation_shape", @{
    @"operation" : [operation isKindOfClass:NSDictionary.class] ? operation
                                                                : NSNull.null,
  })[@"valid"] isEqual:@YES];
}

BOOL DSHWorkspaceClearanceValidateOperation(NSDictionary *operation,
                                            NSError **error) {
  if (!DSHWorkspaceClearanceCanonicalOperationFields(operation)) {
    return DSHWorkspaceClearanceSetError(
        error, DSHWorkspaceClearanceStoreErrorInvalidArgument);
  }
  return YES;
}

static BOOL DSHWorkspaceClearanceReceiptFields(NSDictionary *receipt) {
  return [DSHWorkspaceClearanceReduce(@"receipt_shape", @{
    @"receipt" : [receipt isKindOfClass:NSDictionary.class] ? receipt
                                                            : NSNull.null,
  })[@"valid"] isEqual:@YES];
}

static BOOL DSHWorkspaceClearanceSessionReferenceValid(NSUInteger generation,
                                                       NSString *digest) {
  return [DSHWorkspaceClearanceReduce(@"session_reference_valid", @{
    @"generation" : @((unsigned long long)generation),
    @"sha256" : digest ?: NSNull.null,
  })[@"valid"] isEqual:@YES];
}

static BOOL DSHWorkspaceClearanceWriteAll(int descriptor, NSData *data) {
  const uint8_t *bytes = (const uint8_t *)data.bytes;
  NSUInteger offset = 0;
  while (offset < data.length) {
    ssize_t count = write(descriptor, bytes + offset, data.length - offset);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) return NO;
    offset += (NSUInteger)count;
  }
  return YES;
}

static NSData *DSHWorkspaceClearanceReadAll(int descriptor,
                                            NSUInteger maximumBytes) {
  NSMutableData *data = [NSMutableData data];
  uint8_t buffer[16384];
  while (YES) {
    ssize_t count = read(descriptor, buffer, sizeof(buffer));
    if (count < 0 && errno == EINTR) continue;
    if (count < 0 || (count == 0 && data.length == 0)) return nil;
    if (count == 0) break;
    if (data.length + (NSUInteger)count > maximumBytes) return nil;
    [data appendBytes:buffer length:(NSUInteger)count];
  }
  return data.length == 0 ? nil : [data copy];
}

static BOOL DSHWorkspaceClearanceFileIdentity(struct stat state) {
  return S_ISREG(state.st_mode) && !S_ISLNK(state.st_mode) &&
      state.st_nlink == 1 && (state.st_mode & 0777) == 0600;
}

void DSHWorkspaceClearanceRegisterProjectDetachCheckpoint(
    NSString *workspaceId,
    NSUInteger bindingRevision) {
  if (!DSHWorkspaceClearanceUUID(workspaceId) || bindingRevision == 0 ||
      bindingRevision >= DSHWorkspaceClearanceMaximumSafeInteger) {
    return;
  }
  NSLock *lock = DSHWorkspaceClearanceCheckpointLock();
  [lock lock];
  DSHWorkspaceClearanceCheckpoints()[
      DSHWorkspaceClearanceCheckpointKey(workspaceId, bindingRevision)] = @NO;
  [lock unlock];
}

void DSHWorkspaceClearanceMarkProjectDetachCheckpointDetached(
    NSString *workspaceId,
    NSUInteger bindingRevision) {
  if (!DSHWorkspaceClearanceUUID(workspaceId) || bindingRevision == 0 ||
      bindingRevision >= DSHWorkspaceClearanceMaximumSafeInteger) {
    return;
  }
  NSLock *lock = DSHWorkspaceClearanceCheckpointLock();
  [lock lock];
  NSString *key = DSHWorkspaceClearanceCheckpointKey(workspaceId,
                                                      bindingRevision);
  if (DSHWorkspaceClearanceCheckpoints()[key] != nil) {
    DSHWorkspaceClearanceCheckpoints()[key] = @YES;
  }
  [lock unlock];
}

void DSHWorkspaceClearanceUnregisterProjectDetachCheckpoint(
    NSString *workspaceId,
    NSUInteger bindingRevision) {
  if (!DSHWorkspaceClearanceUUID(workspaceId) || bindingRevision == 0 ||
      bindingRevision >= DSHWorkspaceClearanceMaximumSafeInteger) {
    return;
  }
  NSLock *lock = DSHWorkspaceClearanceCheckpointLock();
  [lock lock];
  [DSHWorkspaceClearanceCheckpoints()
      removeObjectForKey:DSHWorkspaceClearanceCheckpointKey(workspaceId,
                                                             bindingRevision)];
  [lock unlock];
}

static BOOL DSHWorkspaceClearanceValidateNativeProjectRelationDetached(
    NSURL *privateRootURL,
    NSString *workspaceId,
    NSUInteger bindingRevision,
    NSError **error) {
  if (![privateRootURL isKindOfClass:NSURL.class] || !privateRootURL.isFileURL ||
      privateRootURL.path.length == 0 ||
      !DSHWorkspaceClearanceUUID(workspaceId) || bindingRevision == 0 ||
      bindingRevision >= DSHWorkspaceClearanceMaximumSafeInteger) {
    return DSHWorkspaceClearanceSetError(
        error, DSHWorkspaceClearanceStoreErrorInvalidArgument);
  }
  NSString *checkpoint = DSHWorkspaceClearanceCheckpointKey(
      workspaceId, bindingRevision);
  NSLock *checkpointLock = DSHWorkspaceClearanceCheckpointLock();
  [checkpointLock lock];
  NSNumber *checkpointState = DSHWorkspaceClearanceCheckpoints()[checkpoint];
  [checkpointLock unlock];
  if (checkpointState != nil && !checkpointState.boolValue) {
    return DSHWorkspaceClearanceSetError(
        error, DSHWorkspaceClearanceStoreErrorConflict);
  }

  int root = open(privateRootURL.fileSystemRepresentation,
                  O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (root < 0) {
    return DSHWorkspaceClearanceSetError(
        error, errno == ENOENT ? DSHWorkspaceClearanceStoreErrorNotFound
                               : DSHWorkspaceClearanceStoreErrorStorage);
  }
  int gitdirs = openat(root, @"workspace-gitdirs".fileSystemRepresentation,
                       O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (gitdirs < 0 && errno == ENOENT) {
    close(root);
    return YES;
  }
  if (gitdirs < 0) {
    close(root);
    return DSHWorkspaceClearanceSetError(
        error, DSHWorkspaceClearanceStoreErrorStorage);
  }
  int workspace = openat(gitdirs, workspaceId.fileSystemRepresentation,
                         O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (workspace < 0 && errno == ENOENT) {
    close(gitdirs);
    close(root);
    return YES;
  }
  if (workspace < 0) {
    close(gitdirs);
    close(root);
    return DSHWorkspaceClearanceSetError(
        error, DSHWorkspaceClearanceStoreErrorConflict);
  }
  DIR *directory = fdopendir(workspace);
  if (directory == nullptr) {
    close(workspace);
    close(gitdirs);
    close(root);
    return DSHWorkspaceClearanceSetError(
        error, DSHWorkspaceClearanceStoreErrorStorage);
  }
  BOOL detachedCheckpoint = checkpointState != nil && checkpointState.boolValue;
  BOOL detached = YES;
  errno = 0;
  struct dirent *entry = nullptr;
  while ((entry = readdir(directory)) != nullptr) {
    NSString *name = [NSString stringWithUTF8String:entry->d_name];
    if (name == nil || [name isEqual:@"."] || [name isEqual:@".."]) continue;
    // A published project relation is represented by a binding-v2.json
    // record. A detached checkpoint may retain the private gitdir directory,
    // but only after the native project owner has explicitly marked that
    // checkpoint detached. Unknown/staging entries remain fail-closed.
    if ([name hasPrefix:@".rish-attach-"] ||
        !DSHWorkspaceClearanceUUID(name)) {
      detached = NO;
      break;
    }
    int project = openat(workspace, name.fileSystemRepresentation,
                         O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (project < 0) {
      detached = NO;
      break;
    }
    int binding = openat(project, @"binding-v2.json".fileSystemRepresentation,
                         O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    int bindingErrno = errno;
    if (binding >= 0) close(binding);
    close(project);
    if (binding >= 0 || bindingErrno != ENOENT || !detachedCheckpoint) {
      detached = NO;
      break;
    }
  }
  BOOL readError = errno != 0;
  closedir(directory);
  close(gitdirs);
  close(root);
  if (readError) {
    return DSHWorkspaceClearanceSetError(
        error, DSHWorkspaceClearanceStoreErrorStorage);
  }
  if (!detached) {
    return DSHWorkspaceClearanceSetError(
        error, DSHWorkspaceClearanceStoreErrorConflict);
  }
  return YES;
}

BOOL DSHWorkspaceClearanceValidateNativeProjectDetached(
    NSURL *privateRootURL,
    NSString *workspaceId,
    NSUInteger bindingRevision,
    NSError **error) {
  DSHLocalWorkspaceAccess *access = [[DSHLocalWorkspaceAccess alloc]
      initWithPrivateRootURL:privateRootURL
                       clock:^NSDate * { return NSDate.date; }
               UUIDGenerator:^NSString * {
                 return NSUUID.UUID.UUIDString.lowercaseString;
               }
              legacyResolver:^BOOL(__unused NSString *projectId,
                                    NSDictionary **evidence,
                                    NSError **innerError) {
                if (evidence != nil) *evidence = nil;
                if (innerError != nil) {
                  *innerError = [NSError errorWithDomain:
                      DSHLocalWorkspaceAccessErrorDomain
                                                     code:
                      DSHLocalWorkspaceAccessErrorUnavailable
                                                 userInfo:@{}];
                }
                return NO;
              }
                   faultHook:nil];
  NSError *workspaceError = nil;
  DSHLocalWorkspaceAuthorityMutationGuard *guard =
      [access acquireAuthorityMutationGuard:&workspaceError];
  BOOL valid = guard != nil && [access
      validateWorkspaceForClearanceId:workspaceId
                      bindingRevision:bindingRevision
               authorityMutationGuard:guard
                                 error:&workspaceError] &&
      DSHWorkspaceClearanceValidateNativeProjectRelationDetached(
          privateRootURL, workspaceId, bindingRevision, &workspaceError);
  if (!valid && error != nil) {
    *error = [NSError errorWithDomain:DSHWorkspaceClearanceStoreErrorDomain
                                 code:DSHWorkspaceClearanceStoreErrorConflict
                             userInfo:@{
      @"code" : DSHWorkspaceClearanceStoreErrorConflictCode,
      NSLocalizedDescriptionKey : @"Workspace project relation is not detached."
    }];
  }
  return valid;
}

static BOOL DSHWorkspaceClearanceProtectURL(NSURL *url) {
  if (![url isKindOfClass:NSURL.class] || !url.isFileURL) return NO;
  NSFileManager *manager = NSFileManager.defaultManager;
  NSError *attributeError = nil;
  BOOL permissions = [manager setAttributes:@{
    NSFilePosixPermissions : @0600,
  } ofItemAtPath:url.path error:&attributeError];
  BOOL protection = [manager setAttributes:@{
    NSFileProtectionKey : NSFileProtectionComplete,
  } ofItemAtPath:url.path error:&attributeError];
  BOOL excluded = [url setResourceValue:@YES
                                 forKey:NSURLIsExcludedFromBackupKey
                                  error:&attributeError];
#if TARGET_OS_SIMULATOR || TARGET_OS_OSX
  (void)protection;
  (void)excluded;
  return permissions;
#else
  return permissions && protection && excluded;
#endif
}

@interface DSHWorkspaceClearanceStore ()
@property(nonatomic, readwrite, strong) NSURL *privateRootURL;
@property(nonatomic, readwrite, strong) NSURL *receiptURL;
@property(nonatomic, readwrite, strong) DSHSessionWorkspaceCoordinator *coordinator;
@property(nonatomic, copy) DSHWorkspaceClearanceClock clock;
@property(nonatomic, copy) DSHWorkspaceClearanceIdentifierGenerator generator;
@property(nonatomic, copy, nullable) DSHWorkspaceClearanceFaultHook faultHook;
@property(nonatomic, copy, nullable) DSHWorkspaceClearanceProjectDetachValidator
    projectDetachValidator;
- (BOOL)ensurePrivateRoot:(NSError **)error;
- (BOOL)validateProjectDetachedForOperation:(NSDictionary *)operation
                                      error:(NSError **)error;
- (int)acquireLock:(NSError **)error;
- (nullable NSArray<NSDictionary *> *)readReceiptsLocked:(NSError **)error;
- (BOOL)writeEnvelopeLocked:(NSArray<NSDictionary *> *)receipts
                      error:(NSError **)error
                 writeResult:(DSHWorkspaceClearanceAtomicWriteResult *)result;
- (nullable NSDictionary *)issueReceiptLocked:(NSDictionary *)operation
                    committedSessionGeneration:(NSUInteger)generation
                            committedSessionSHA256:(NSString *)sessionSHA256
                         projectAlreadyValidated:(BOOL)projectAlreadyValidated
                                             error:(NSError **)error;
- (nullable NSDictionary *)queryReceiptLocked:(NSString *)operationId
                     currentSessionGeneration:(NSUInteger)generation
                             currentSessionSHA256:(nullable NSString *)sessionSHA256
                                          error:(NSError **)error;
- (BOOL)validateReceiptLocked:(NSDictionary *)receipt
                  operationId:(NSString *)operationId
                  workspaceId:(NSString *)workspaceId
            bindingRevision:(NSUInteger)bindingRevision
       currentSessionGeneration:(NSUInteger)generation
               currentSessionSHA256:(NSString *)sessionSHA256
                             error:(NSError **)error;
@end

@implementation DSHWorkspaceClearanceStore

- (instancetype)initWithPrivateRootURL:(NSURL *)privateRootURL {
  return [self initWithPrivateRootURL:privateRootURL
                          coordinator:nil
                                clock:nil
                   identifierGenerator:nil
                            faultHook:nil
               projectDetachValidator:nil];
}

- (instancetype)initWithPrivateRootURL:(NSURL *)privateRootURL
                           coordinator:(DSHSessionWorkspaceCoordinator *)coordinator
                                 clock:(DSHWorkspaceClearanceClock)clock
                    identifierGenerator:(DSHWorkspaceClearanceIdentifierGenerator)generator
                             faultHook:(DSHWorkspaceClearanceFaultHook)faultHook {
  return [self initWithPrivateRootURL:privateRootURL
                          coordinator:coordinator
                                clock:clock
                   identifierGenerator:generator
                            faultHook:faultHook
               projectDetachValidator:nil];
}

- (instancetype)initWithPrivateRootURL:(NSURL *)privateRootURL
                           coordinator:(DSHSessionWorkspaceCoordinator *)coordinator
                                 clock:(DSHWorkspaceClearanceClock)clock
                    identifierGenerator:(DSHWorkspaceClearanceIdentifierGenerator)generator
                             faultHook:(DSHWorkspaceClearanceFaultHook)faultHook
                projectDetachValidator:
                    (DSHWorkspaceClearanceProjectDetachValidator)projectDetachValidator {
  if (![privateRootURL isKindOfClass:NSURL.class] || !privateRootURL.isFileURL ||
      privateRootURL.path.length == 0) {
    return nil;
  }
  self = [super init];
  if (self != nil) {
    NSString *rootPath = privateRootURL.path.stringByStandardizingPath;
    _privateRootURL = [NSURL fileURLWithPath:rootPath isDirectory:YES];
    _receiptURL = [_privateRootURL
        URLByAppendingPathComponent:DSHWorkspaceClearanceFilename
                         isDirectory:NO];
    _coordinator = coordinator ?: [DSHSessionWorkspaceCoordinator sharedCoordinator];
    _clock = [clock copy];
    if (_clock == nil) {
      _clock = ^NSDate *{
        return [NSDate date];
      };
    }
    _generator = [generator copy];
    if (_generator == nil) {
      _generator = ^NSString *{
        return NSUUID.UUID.UUIDString.lowercaseString;
      };
    }
    _faultHook = [faultHook copy];
    _projectDetachValidator = [projectDetachValidator copy];
  }
  return self;
}

- (BOOL)faultAtPoint:(DSHWorkspaceClearanceFaultPoint)point {
  if (self.faultHook == nil) return YES;
  @try {
    return self.faultHook(point);
  } @catch (__unused NSException *exception) {
    return NO;
  }
}

- (BOOL)ensurePrivateRoot:(NSError **)error {
  NSURL *parent = self.privateRootURL.URLByDeletingLastPathComponent;
  if (parent == nil || !parent.isFileURL) {
    return DSHWorkspaceClearanceSetError(
        error, DSHWorkspaceClearanceStoreErrorStorage);
  }
  NSFileManager *manager = NSFileManager.defaultManager;
  struct stat parentState = {};
  if (lstat(parent.fileSystemRepresentation, &parentState) != 0 ||
      !S_ISDIR(parentState.st_mode) || S_ISLNK(parentState.st_mode)) {
    return DSHWorkspaceClearanceSetError(
        error, DSHWorkspaceClearanceStoreErrorStorage);
  }
  struct stat state = {};
  if (lstat(self.privateRootURL.fileSystemRepresentation, &state) != 0) {
    if (errno != ENOENT ||
        ![manager createDirectoryAtURL:self.privateRootURL
            withIntermediateDirectories:NO
                             attributes:@{ NSFilePosixPermissions : @0700 }
                                  error:nil]) {
      return DSHWorkspaceClearanceSetError(
          error, DSHWorkspaceClearanceStoreErrorStorage);
    }
    if (lstat(self.privateRootURL.fileSystemRepresentation, &state) != 0) {
      return DSHWorkspaceClearanceSetError(
          error, DSHWorkspaceClearanceStoreErrorStorage);
    }
  }
  if (!S_ISDIR(state.st_mode) || S_ISLNK(state.st_mode) ||
      chmod(self.privateRootURL.fileSystemRepresentation, 0700) != 0) {
    return DSHWorkspaceClearanceSetError(
        error, DSHWorkspaceClearanceStoreErrorStorage);
  }
  (void)[self.privateRootURL setResourceValue:@YES
                                        forKey:NSURLIsExcludedFromBackupKey
                                         error:nil];
  return YES;
}

- (int)acquireLock:(NSError **)error {
  NSURL *lockURL = [self.privateRootURL
      URLByAppendingPathComponent:DSHWorkspaceClearanceLockFilename
                       isDirectory:NO];
  int descriptor = open(lockURL.fileSystemRepresentation,
                        O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (descriptor < 0) {
    DSHWorkspaceClearanceSetError(error,
                                  DSHWorkspaceClearanceStoreErrorStorage);
    return -1;
  }
  struct stat state = {};
  if (fstat(descriptor, &state) != 0 || !DSHWorkspaceClearanceFileIdentity(state) ||
      fchmod(descriptor, 0600) != 0) {
    close(descriptor);
    DSHWorkspaceClearanceSetError(error,
                                  DSHWorkspaceClearanceStoreErrorStorage);
    return -1;
  }
  if (!DSHWorkspaceClearanceProtectURL(lockURL)) {
    close(descriptor);
    DSHWorkspaceClearanceSetError(error,
                                  DSHWorkspaceClearanceStoreErrorStorage);
    return -1;
  }
  int locked = 0;
  do {
    locked = flock(descriptor, LOCK_EX);
  } while (locked != 0 && errno == EINTR);
  if (locked != 0 || fsync(descriptor) != 0) {
    close(descriptor);
    DSHWorkspaceClearanceSetError(error,
                                  DSHWorkspaceClearanceStoreErrorStorage);
    return -1;
  }
  return descriptor;
}

- (nullable NSArray<NSDictionary *> *)readReceiptsLocked:(NSError **)error {
  NSURL *temporaryURL = [self.privateRootURL
      URLByAppendingPathComponent:DSHWorkspaceClearanceTemporaryFilename
                       isDirectory:NO];
  int descriptor = open(temporaryURL.fileSystemRepresentation,
                        O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (descriptor >= 0) {
    close(descriptor);
    DSHWorkspaceClearanceSetError(error,
                                  DSHWorkspaceClearanceStoreErrorCorrupt);
    return nil;
  }
  if (errno != ENOENT) {
    DSHWorkspaceClearanceSetError(error,
                                  DSHWorkspaceClearanceStoreErrorStorage);
    return nil;
  }
  descriptor = open(self.receiptURL.fileSystemRepresentation,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (descriptor < 0) {
    if (errno == ENOENT) return @[];
    DSHWorkspaceClearanceSetError(error,
                                  DSHWorkspaceClearanceStoreErrorStorage);
    return nil;
  }
  struct stat state = {};
  BOOL fileOK = fstat(descriptor, &state) == 0 &&
      DSHWorkspaceClearanceFileIdentity(state) &&
      state.st_size > 0 &&
      (uint64_t)state.st_size <= DSHWorkspaceClearanceMaximumBytes;
  NSData *data = fileOK
      ? DSHWorkspaceClearanceReadAll(descriptor,
                                     DSHWorkspaceClearanceMaximumBytes)
      : nil;
  struct stat after = {};
  BOOL stable = data != nil && fstat(descriptor, &after) == 0 &&
      after.st_dev == state.st_dev && after.st_ino == state.st_ino &&
      after.st_size == state.st_size;
  close(descriptor);
  if (!stable) {
    DSHWorkspaceClearanceSetError(
        error, fileOK ? DSHWorkspaceClearanceStoreErrorConflict
                      : DSHWorkspaceClearanceStoreErrorCorrupt);
    return nil;
  }
  NSError *decodeError = nil;
  id object = [NSJSONSerialization JSONObjectWithData:data
                                                options:0
                                                  error:&decodeError];
  if (!DSHWorkspaceClearanceDictionary(object) ||
      !DSHWorkspaceClearanceExactKeys(object, @[@"schema_version", @"receipts"]) ||
      !DSHWorkspaceClearanceSafeInteger(object[@"schema_version"], YES) ||
      [object[@"schema_version"] unsignedIntegerValue] != 1 ||
      !DSHWorkspaceClearanceArray(object[@"receipts"]) ||
      [object[@"receipts"] count] > DSHWorkspaceClearanceMaximumReceipts) {
    DSHWorkspaceClearanceSetError(
        error, DSHWorkspaceClearanceStoreErrorCorrupt);
    return nil;
  }
  NSError *canonicalError = nil;
  NSData *canonical = DSHWorkspaceCanonicalJSONData(object, &canonicalError);
  if (canonical == nil || ![canonical isEqualToData:data]) {
    DSHWorkspaceClearanceSetError(
        error, DSHWorkspaceClearanceStoreErrorCorrupt);
    return nil;
  }
  NSMutableSet *operationIds = [NSMutableSet set];
  NSMutableSet *receiptIds = [NSMutableSet set];
  for (id value in object[@"receipts"]) {
    if (!DSHWorkspaceClearanceReceiptFields(value)) {
      DSHWorkspaceClearanceSetError(
          error, DSHWorkspaceClearanceStoreErrorCorrupt);
      return nil;
    }
    NSString *operationId = value[@"operation_id"];
    NSString *receiptId = value[@"clearance_receipt_id"];
    if ([operationIds containsObject:operationId] ||
        [receiptIds containsObject:receiptId]) {
      DSHWorkspaceClearanceSetError(
          error, DSHWorkspaceClearanceStoreErrorCorrupt);
      return nil;
    }
    [operationIds addObject:operationId];
    [receiptIds addObject:receiptId];
  }
  return [object[@"receipts"] copy];
}

- (BOOL)writeEnvelopeLocked:(NSArray<NSDictionary *> *)receipts
                      error:(NSError **)error
                 writeResult:(DSHWorkspaceClearanceAtomicWriteResult *)result {
  if (result != nullptr) *result = DSHWorkspaceClearanceAtomicWriteNoEffect;
  NSDictionary *envelope = @{
    @"schema_version" : @1,
    @"receipts" : receipts ?: @[],
  };
  NSError *canonicalError = nil;
  NSData *data = DSHWorkspaceCanonicalJSONData(envelope, &canonicalError);
  if (data == nil || data.length == 0 ||
      data.length > DSHWorkspaceClearanceMaximumBytes) {
    return DSHWorkspaceClearanceSetError(
        error, DSHWorkspaceClearanceStoreErrorBounds);
  }
  if (![self faultAtPoint:DSHWorkspaceClearanceFaultPointBeforeWrite]) {
    return DSHWorkspaceClearanceSetError(
        error, DSHWorkspaceClearanceStoreErrorStorage);
  }
  int root = open(self.privateRootURL.fileSystemRepresentation,
                  O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (root < 0) {
    return DSHWorkspaceClearanceSetError(
        error, DSHWorkspaceClearanceStoreErrorStorage);
  }
  struct stat temporary = {};
  if (fstatat(root, DSHWorkspaceClearanceTemporaryFilename.fileSystemRepresentation,
              &temporary, AT_SYMLINK_NOFOLLOW) == 0) {
    close(root);
    return DSHWorkspaceClearanceSetError(
        error, DSHWorkspaceClearanceStoreErrorCorrupt);
  }
  if (errno != ENOENT) {
    close(root);
    return DSHWorkspaceClearanceSetError(
        error, DSHWorkspaceClearanceStoreErrorStorage);
  }
  int staged = openat(root, DSHWorkspaceClearanceTemporaryFilename.fileSystemRepresentation,
                      O_WRONLY | O_CREAT | O_EXCL | O_TRUNC | O_NOFOLLOW, 0600);
  if (staged < 0) {
    close(root);
    return DSHWorkspaceClearanceSetError(
        error, DSHWorkspaceClearanceStoreErrorStorage);
  }
  NSURL *temporaryURL = [self.privateRootURL
      URLByAppendingPathComponent:DSHWorkspaceClearanceTemporaryFilename
                       isDirectory:NO];
  BOOL written = DSHWorkspaceClearanceWriteAll(staged, data) &&
      fchmod(staged, 0600) == 0 &&
      DSHWorkspaceClearanceProtectURL(temporaryURL) && fsync(staged) == 0;
  struct stat stagedState = {};
  BOOL stagedIdentity = fstat(staged, &stagedState) == 0 &&
      DSHWorkspaceClearanceFileIdentity(stagedState) &&
      stagedState.st_size == (off_t)data.length;
  close(staged);
  if (!written || !stagedIdentity) {
    unlinkat(root, DSHWorkspaceClearanceTemporaryFilename.fileSystemRepresentation, 0);
    close(root);
    return DSHWorkspaceClearanceSetError(
        error, DSHWorkspaceClearanceStoreErrorStorage);
  }
  if (![self faultAtPoint:DSHWorkspaceClearanceFaultPointAfterWriteBeforeRename]) {
    unlinkat(root, DSHWorkspaceClearanceTemporaryFilename.fileSystemRepresentation, 0);
    close(root);
    return DSHWorkspaceClearanceSetError(
        error, DSHWorkspaceClearanceStoreErrorStorage);
  }
  if (renameat(root, DSHWorkspaceClearanceTemporaryFilename.fileSystemRepresentation,
               root, DSHWorkspaceClearanceFilename.fileSystemRepresentation) != 0) {
    close(root);
    return DSHWorkspaceClearanceSetError(
        error, DSHWorkspaceClearanceStoreErrorStorage);
  }
  if (result != nullptr) *result = DSHWorkspaceClearanceAtomicWriteUnknown;
  if (![self faultAtPoint:DSHWorkspaceClearanceFaultPointAfterRename]) {
    close(root);
    DSHWorkspaceClearanceSetError(
        error, DSHWorkspaceClearanceStoreErrorStorage);
    return NO;
  }
  struct stat published = {};
  BOOL publishedIdentity = fstatat(
      root, DSHWorkspaceClearanceFilename.fileSystemRepresentation, &published,
      AT_SYMLINK_NOFOLLOW) == 0 &&
      DSHWorkspaceClearanceFileIdentity(published) &&
      published.st_dev == stagedState.st_dev &&
      published.st_ino == stagedState.st_ino &&
      published.st_size == stagedState.st_size;
  BOOL synced = fsync(root) == 0;
  if (!publishedIdentity || !synced ||
      ![self faultAtPoint:DSHWorkspaceClearanceFaultPointAfterRenameBeforeVerify]) {
    close(root);
    DSHWorkspaceClearanceSetError(
        error, DSHWorkspaceClearanceStoreErrorStorage);
    return NO;
  }
  int verify = openat(root, DSHWorkspaceClearanceFilename.fileSystemRepresentation,
                      O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  struct stat verified = {};
  BOOL verifiedOK = verify >= 0 && fstat(verify, &verified) == 0 &&
      DSHWorkspaceClearanceFileIdentity(verified) &&
      verified.st_dev == stagedState.st_dev &&
      verified.st_ino == stagedState.st_ino &&
      verified.st_size == (off_t)data.length;
  if (verify >= 0) close(verify);
  close(root);
  if (!verifiedOK) {
    DSHWorkspaceClearanceSetError(
        error, DSHWorkspaceClearanceStoreErrorStorage);
    return NO;
  }
  if (result != nullptr) *result = DSHWorkspaceClearanceAtomicWriteCommitted;
  return YES;
}

- (BOOL)validateProjectDetachedForOperation:(NSDictionary *)operation
                                      error:(NSError **)error {
  if (!DSHWorkspaceClearanceValidateOperation(operation, error)) return NO;
  DSHWorkspaceClearanceProjectDetachValidator validator =
      self.projectDetachValidator;
  if (validator == nil) {
    validator = ^BOOL(NSURL *rootURL, NSString *workspaceId,
                      NSUInteger bindingRevision, NSError **innerError) {
      return DSHWorkspaceClearanceValidateNativeProjectDetached(
          rootURL, workspaceId, bindingRevision, innerError);
    };
  }
  @try {
    return validator(self.privateRootURL, operation[@"workspace_id"],
                     [operation[@"binding_revision"] unsignedIntegerValue],
                     error);
  } @catch (__unused NSException *exception) {
    return DSHWorkspaceClearanceSetError(
        error, DSHWorkspaceClearanceStoreErrorStorage);
  }
}

- (BOOL)validateProjectDetachedForOperation:(NSDictionary *)operation
                            workspaceAccess:(DSHLocalWorkspaceAccess *)workspaceAccess
                     authorityMutationGuard:
                         (DSHLocalWorkspaceAuthorityMutationGuard *)guard
                                      error:(NSError **)error {
  if (!DSHWorkspaceClearanceValidateOperation(operation, error) ||
      workspaceAccess == nil || guard == nil) return NO;
  if (self.projectDetachValidator != nil) {
    @try {
      return self.projectDetachValidator(
          self.privateRootURL, operation[@"workspace_id"],
          [operation[@"binding_revision"] unsignedIntegerValue], error);
    } @catch (__unused NSException *exception) {
      return DSHWorkspaceClearanceSetError(
          error, DSHWorkspaceClearanceStoreErrorStorage);
    }
  }
  NSError *workspaceError = nil;
  BOOL valid = [workspaceAccess
      validateWorkspaceForClearanceId:operation[@"workspace_id"]
                      bindingRevision:
                          [operation[@"binding_revision"] unsignedIntegerValue]
               authorityMutationGuard:guard
                                 error:&workspaceError] &&
      DSHWorkspaceClearanceValidateNativeProjectRelationDetached(
          self.privateRootURL, operation[@"workspace_id"],
          [operation[@"binding_revision"] unsignedIntegerValue],
          &workspaceError);
  if (!valid) {
    return DSHWorkspaceClearanceSetError(
        error, DSHWorkspaceClearanceStoreErrorConflict);
  }
  return YES;
}

- (nullable NSDictionary *)issueReceiptLocked:(NSDictionary *)operation
                    committedSessionGeneration:(NSUInteger)generation
                            committedSessionSHA256:(NSString *)sessionSHA256
                         projectAlreadyValidated:(BOOL)projectAlreadyValidated
                                             error:(NSError **)error {
  if ((!projectAlreadyValidated &&
       ![self validateProjectDetachedForOperation:operation error:error]) ||
      !DSHWorkspaceClearanceSessionReferenceValid(generation, sessionSHA256)) {
    if (error != nullptr && *error == nil) {
      DSHWorkspaceClearanceSetError(
          error, DSHWorkspaceClearanceStoreErrorInvalidArgument);
    }
    return nil;
  }
  NSError *readError = nil;
  NSArray<NSDictionary *> *existing = [self readReceiptsLocked:&readError];
  if (existing == nil) {
    if (error != nullptr) *error = readError;
    return nil;
  }
  NSMutableArray *receipts = [existing mutableCopy];
  NSDate *now = nil;
  @try {
    now = self.clock();
  } @catch (__unused NSException *exception) {
    now = nil;
  }
  NSString *issuedAt = DSHWorkspaceClearanceTimestampForDate(now);
  if (issuedAt == nil) {
    DSHWorkspaceClearanceSetError(
        error, DSHWorkspaceClearanceStoreErrorStorage);
    return nil;
  }
  NSDate *currentDate = DSHWorkspaceClearanceDateFromTimestamp(issuedAt);
  NSIndexSet *expired = [receipts indexesOfObjectsPassingTest:
      ^BOOL(NSDictionary *receipt, NSUInteger index, BOOL *stop) {
        NSDate *date = DSHWorkspaceClearanceDateFromTimestamp(receipt[@"issued_at"]);
        return date != nil && [currentDate timeIntervalSinceDate:date] >=
            DSHWorkspaceClearanceTTL;
      }];
  if (expired.count > 0) [receipts removeObjectsAtIndexes:expired];

  NSString *operationId = operation[@"operation_id"];
  NSString *clearanceId = operation[@"clearance_receipt_id"];
  for (NSDictionary *receipt in receipts) {
    BOOL operationMatches = [receipt[@"operation_id"] isEqual:operationId];
    BOOL clearanceMatches = [receipt[@"clearance_receipt_id"] isEqual:clearanceId];
    if (!operationMatches && !clearanceMatches) continue;
    BOOL same = operationMatches && clearanceMatches &&
        [receipt[@"workspace_id"] isEqual:operation[@"workspace_id"]] &&
        [receipt[@"binding_revision"] isEqual:operation[@"binding_revision"]] &&
        [receipt[@"committed_session_generation"] unsignedIntegerValue] == generation &&
        [receipt[@"committed_session_sha256"] isEqual:sessionSHA256];
    if (same) return [receipt copy];
    DSHWorkspaceClearanceSetError(
        error, DSHWorkspaceClearanceStoreErrorConflict);
    return nil;
  }
  if (receipts.count >= DSHWorkspaceClearanceMaximumReceipts) {
    DSHWorkspaceClearanceSetError(
        error, DSHWorkspaceClearanceStoreErrorBusy);
    return nil;
  }
  NSDictionary *receipt = @{
    @"schema_version" : @1,
    @"clearance_receipt_id" : clearanceId,
    @"operation_id" : operationId,
    @"workspace_id" : operation[@"workspace_id"],
    @"binding_revision" : operation[@"binding_revision"],
    @"committed_session_generation" : @(generation),
    @"committed_session_sha256" : sessionSHA256,
    @"issued_at" : issuedAt,
  };
  [receipts addObject:receipt];
  DSHWorkspaceClearanceAtomicWriteResult writeResult =
      DSHWorkspaceClearanceAtomicWriteNoEffect;
  NSError *writeError = nil;
  BOOL written = [self writeEnvelopeLocked:receipts
                                     error:&writeError
                                writeResult:&writeResult];
  if (!written || writeResult != DSHWorkspaceClearanceAtomicWriteCommitted) {
    if (error != nullptr) *error = writeError ?: DSHWorkspaceClearanceError(
        DSHWorkspaceClearanceStoreErrorStorage);
    return nil;
  }
  return [receipt copy];
}

- (nullable NSDictionary *)queryReceiptLocked:(NSString *)operationId
                     currentSessionGeneration:(NSUInteger)generation
                             currentSessionSHA256:(NSString *)sessionSHA256
                                          error:(NSError **)error {
  if (!DSHWorkspaceClearanceUUID(operationId) || generation == 0 ||
      !DSHWorkspaceClearanceDigest(sessionSHA256)) {
    DSHWorkspaceClearanceSetError(
        error, DSHWorkspaceClearanceStoreErrorInvalidArgument);
    return nil;
  }
  NSError *readError = nil;
  NSArray<NSDictionary *> *receipts = [self readReceiptsLocked:&readError];
  if (receipts == nil) {
    // Query cannot prove absence from a corrupt/unavailable private store.
    return @{
      @"schema_version" : @1,
      @"status" : @"unknown",
    };
  }
  NSDate *now = nil;
  @try {
    now = self.clock();
  } @catch (__unused NSException *exception) {
    now = nil;
  }
  NSMutableArray *live = [NSMutableArray array];
  for (NSDictionary *receipt in receipts) {
    NSDate *issued = DSHWorkspaceClearanceDateFromTimestamp(receipt[@"issued_at"]);
    if (issued != nil && now != nil &&
        [now timeIntervalSinceDate:issued] >= DSHWorkspaceClearanceTTL) {
      continue;
    }
    [live addObject:receipt];
  }
  for (NSDictionary *receipt in live) {
    if (![receipt[@"operation_id"] isEqual:operationId]) continue;
    BOOL current = [receipt[@"committed_session_generation"] unsignedIntegerValue] ==
            generation &&
        [receipt[@"committed_session_sha256"] isEqual:sessionSHA256];
    if (!current) {
      return @{
        @"schema_version" : @1,
        @"status" : @"unknown",
      };
    }
    return @{
      @"schema_version" : @1,
      @"status" : @"committed",
      @"receipt" : [receipt copy],
    };
  }
  return @{
    @"schema_version" : @1,
    @"status" : @"not_started",
  };
}

- (BOOL)validateReceiptLocked:(NSDictionary *)receipt
                  operationId:(NSString *)operationId
                  workspaceId:(NSString *)workspaceId
            bindingRevision:(NSUInteger)bindingRevision
       currentSessionGeneration:(NSUInteger)generation
               currentSessionSHA256:(NSString *)sessionSHA256
                             error:(NSError **)error {
  if (!DSHWorkspaceClearanceReceiptFields(receipt) ||
      !DSHWorkspaceClearanceUUID(operationId) ||
      !DSHWorkspaceClearanceUUID(workspaceId) || generation == 0 ||
      !DSHWorkspaceClearanceDigest(sessionSHA256) ||
      [receipt[@"operation_id"] isEqual:operationId] == NO ||
      [receipt[@"workspace_id"] isEqual:workspaceId] == NO ||
      [receipt[@"binding_revision"] unsignedIntegerValue] != bindingRevision ||
      [receipt[@"committed_session_generation"] unsignedIntegerValue] != generation ||
      ![receipt[@"committed_session_sha256"] isEqual:sessionSHA256]) {
    return DSHWorkspaceClearanceSetError(
        error, DSHWorkspaceClearanceStoreErrorInvalidArgument);
  }
  NSError *readError = nil;
  NSArray<NSDictionary *> *receipts = [self readReceiptsLocked:&readError];
  if (receipts == nil) {
    if (error != nullptr) *error = readError;
    return NO;
  }
  for (NSDictionary *stored in receipts) {
    if (![stored[@"clearance_receipt_id"] isEqual:
          receipt[@"clearance_receipt_id"]]) continue;
    if (![stored isEqual:receipt]) {
      return DSHWorkspaceClearanceSetError(
          error, DSHWorkspaceClearanceStoreErrorConflict);
    }
    NSDate *now = nil;
    @try {
      now = self.clock();
    } @catch (__unused NSException *exception) {
      now = nil;
    }
    NSDate *issued = DSHWorkspaceClearanceDateFromTimestamp(stored[@"issued_at"]);
    if (now == nil || issued == nil ||
        [now timeIntervalSinceDate:issued] >= DSHWorkspaceClearanceTTL) {
      return DSHWorkspaceClearanceSetError(
          error, DSHWorkspaceClearanceStoreErrorConflict);
    }
    return YES;
  }
  return DSHWorkspaceClearanceSetError(
      error, DSHWorkspaceClearanceStoreErrorNotFound);
}

- (nullable NSDictionary *)issueReceiptForOperation:(NSDictionary *)operation
                    committedSessionGeneration:(NSUInteger)generation
                            committedSessionSHA256:(NSString *)sessionSHA256
                                             error:(NSError **)error {
  __block NSDictionary *result = nil;
  __block NSError *operationError = nil;
  BOOL completed = [self.coordinator performSyncWithError:^BOOL(NSError **inner) {
    if (![self ensurePrivateRoot:&operationError]) {
      if (inner != nullptr) *inner = operationError;
      return NO;
    }
    int lock = [self acquireLock:&operationError];
    if (lock < 0) {
      if (inner != nullptr) *inner = operationError;
      return NO;
    }
    @try {
      result = [self issueReceiptForOperation:operation
                   committedSessionGeneration:generation
                           committedSessionSHA256:sessionSHA256
                                lockDescriptor:lock
                                           error:&operationError];
      if (result == nil && inner != nullptr) *inner = operationError;
      return result != nil;
    } @finally {
      close(lock);
    }
  } error:error];
  if (!completed && error != nullptr && *error == nil) {
    *error = operationError ?: DSHWorkspaceClearanceError(
        DSHWorkspaceClearanceStoreErrorStorage);
  }
  return result;
}

- (nullable NSDictionary *)issueReceiptForOperation:(NSDictionary *)operation
                    committedSessionGeneration:(NSUInteger)generation
                            committedSessionSHA256:(NSString *)sessionSHA256
                                 lockDescriptor:(int)lockDescriptor
                                            error:(NSError **)error {
  if (lockDescriptor < 0 || ![self ensurePrivateRoot:error]) return nil;
  return [self issueReceiptLocked:operation
          committedSessionGeneration:generation
                  committedSessionSHA256:sessionSHA256
               projectAlreadyValidated:NO
                                   error:error];
}

- (NSDictionary *)issueReceiptForOperation:(NSDictionary *)operation
                 committedSessionGeneration:(NSUInteger)generation
                         committedSessionSHA256:(NSString *)sessionSHA256
                              lockDescriptor:(int)lockDescriptor
                             workspaceAccess:(DSHLocalWorkspaceAccess *)workspaceAccess
                      authorityMutationGuard:
                          (DSHLocalWorkspaceAuthorityMutationGuard *)guard
                                       error:(NSError **)error {
  if (lockDescriptor < 0 || ![self ensurePrivateRoot:error] ||
      ![self validateProjectDetachedForOperation:operation
                                 workspaceAccess:workspaceAccess
                          authorityMutationGuard:guard error:error]) {
    return nil;
  }
  return [self issueReceiptLocked:operation
          committedSessionGeneration:generation
                  committedSessionSHA256:sessionSHA256
               projectAlreadyValidated:YES
                                   error:error];
}

- (nullable NSDictionary *)storeReceiptForOperation:(NSDictionary *)operation
                       committedSessionGeneration:(NSUInteger)generation
                               committedSessionSHA256:(NSString *)sessionSHA256
                                                error:(NSError **)error {
  return [self issueReceiptForOperation:operation
              committedSessionGeneration:generation
                      committedSessionSHA256:sessionSHA256
                                       error:error];
}

- (nullable NSDictionary *)queryReceiptForOperationId:(NSString *)operationId
                             currentSessionGeneration:(NSUInteger)generation
                                     currentSessionSHA256:(NSString *)sessionSHA256
                                                  error:(NSError **)error {
  __block NSDictionary *result = nil;
  __block NSError *operationError = nil;
  BOOL completed = [self.coordinator performSyncWithError:^BOOL(NSError **inner) {
    if (!DSHWorkspaceClearanceUUID(operationId)) {
      operationError = DSHWorkspaceClearanceError(
          DSHWorkspaceClearanceStoreErrorInvalidArgument);
      if (inner != nullptr) *inner = operationError;
      return NO;
    }
    if (![self ensurePrivateRoot:&operationError]) {
      result = @{ @"schema_version" : @1, @"status" : @"unknown" };
      return YES;
    }
    int lock = [self acquireLock:&operationError];
    if (lock < 0) {
      result = @{ @"schema_version" : @1, @"status" : @"unknown" };
      return YES;
    }
    @try {
      result = [self queryReceiptForOperationId:operationId
                    currentSessionGeneration:generation
                            currentSessionSHA256:sessionSHA256
                                lockDescriptor:lock
                                           error:&operationError];
      if (result == nil) {
        result = @{ @"schema_version" : @1, @"status" : @"unknown" };
      }
      return YES;
    } @finally {
      close(lock);
    }
  } error:error];
  if (!completed && error != nullptr && *error == nil) {
    *error = operationError ?: DSHWorkspaceClearanceError(
        DSHWorkspaceClearanceStoreErrorStorage);
  }
  return result;
}

- (nullable NSDictionary *)queryReceiptForOperationId:(NSString *)operationId
                             currentSessionGeneration:(NSUInteger)generation
                                     currentSessionSHA256:(NSString *)sessionSHA256
                                         lockDescriptor:(int)lockDescriptor
                                                  error:(NSError **)error {
  if (lockDescriptor < 0 || ![self ensurePrivateRoot:error]) return nil;
  return [self queryReceiptLocked:operationId
         currentSessionGeneration:generation
                 currentSessionSHA256:sessionSHA256
                              error:error];
}

- (nullable NSDictionary *)queryClearanceForOperationId:(NSString *)operationId
                               currentSessionGeneration:(NSUInteger)generation
                                       currentSessionSHA256:(NSString *)sessionSHA256
                                                    error:(NSError **)error {
  return [self queryReceiptForOperationId:operationId
                currentSessionGeneration:generation
                        currentSessionSHA256:sessionSHA256
                                     error:error];
}

- (nullable NSDictionary *)queryReceiptForWriteId:(NSString *)writeId
                          currentSessionGeneration:(NSUInteger)generation
                                  currentSessionSHA256:(NSString *)sessionSHA256
                                               error:(NSError **)error {
  return [self queryReceiptForOperationId:writeId
                currentSessionGeneration:generation
                        currentSessionSHA256:sessionSHA256
                                     error:error];
}

- (BOOL)validateReceipt:(NSDictionary *)receipt
            operationId:(NSString *)operationId
            workspaceId:(NSString *)workspaceId
      bindingRevision:(NSUInteger)bindingRevision
currentSessionGeneration:(NSUInteger)generation
    currentSessionSHA256:(NSString *)sessionSHA256
                  error:(NSError **)error {
  __block BOOL valid = NO;
  __block NSError *operationError = nil;
  BOOL completed = [self.coordinator performSyncWithError:^BOOL(NSError **inner) {
    if (![self ensurePrivateRoot:&operationError]) {
      if (inner != nullptr) *inner = operationError;
      return NO;
    }
    int lock = [self acquireLock:&operationError];
    if (lock < 0) {
      if (inner != nullptr) *inner = operationError;
      return NO;
    }
    @try {
      valid = [self validateReceiptLocked:receipt
                              operationId:operationId
                              workspaceId:workspaceId
                        bindingRevision:bindingRevision
                   currentSessionGeneration:generation
                           currentSessionSHA256:sessionSHA256
                                         error:&operationError];
      if (!valid && inner != nullptr) *inner = operationError;
      return valid;
    } @finally {
      close(lock);
    }
  } error:error];
  if (!completed && error != nullptr && *error == nil) {
    *error = operationError ?: DSHWorkspaceClearanceError(
        DSHWorkspaceClearanceStoreErrorStorage);
  }
  return valid;
}

@end
