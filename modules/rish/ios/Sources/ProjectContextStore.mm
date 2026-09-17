#import "ProjectContextStore.h"

#include "rish_agent_core.h"

#import <CommonCrypto/CommonDigest.h>

#include <fcntl.h>
#include <math.h>
#include <sys/stat.h>
#include <unistd.h>

NSErrorDomain const DSHProjectContextStoreErrorDomain =
    @"dev.zseven.rish.project-context-store";
const NSUInteger DSHProjectContextStoreDefaultCapacityBytes = 64 * 1024 * 1024;

static const NSUInteger DSHStoreMaxRecordBytes = 1024 * 1024;
static const NSUInteger DSHStoreMaxReferenceBytes = 1024 * 1024;

@interface DSHProjectContextAuthorizationLease ()
@property(nonatomic, weak) DSHProjectContextStore *store;
@property(nonatomic, copy, readwrite) NSDictionary *snapshot;
@property(nonatomic, copy) NSString *snapshotId;
@property(nonatomic) BOOL finished;
@end

@implementation DSHProjectContextAuthorizationLease
@end

static NSError *DSHStoreError(DSHProjectContextStoreErrorCode code) {
  NSString *message = @"Project context storage is unavailable.";
  switch (code) {
    case DSHProjectContextStoreErrorInvalidArgument:
      message = @"Project context storage input is invalid.";
      break;
    case DSHProjectContextStoreErrorIntegrity:
      message = @"Project context snapshot failed integrity validation.";
      break;
    case DSHProjectContextStoreErrorNotFound:
      message = @"Project context snapshot is unavailable.";
      break;
    case DSHProjectContextStoreErrorCapacity:
      message = @"Project context storage capacity is exhausted.";
      break;
    case DSHProjectContextStoreErrorUnavailable:
      break;
  }
  return [NSError errorWithDomain:DSHProjectContextStoreErrorDomain
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey : message}];
}

static void DSHSetStoreError(NSError **error,
                             DSHProjectContextStoreErrorCode code) {
  if (error != nil) *error = DSHStoreError(code);
}

static NSString *const DSHPrepareNoPriorSnapshotId =
    @"00000000-0000-0000-0000-000000000000";

// How the store names what it keeps, and what an interrupted prepare
// transaction resolves to, live in the shared core (modules/rish/core,
// `rish_agent_project_context_store_reduce`).
static NSDictionary *DSHStoreReduce(NSString *op, NSDictionary *fields) {
  NSMutableDictionary *envelope = [fields mutableCopy];
  envelope[@"op"] = op;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:envelope options:0
                                                    error:nil];
  char *raw = bytes == nil ? NULL : rish_agent_project_context_store_reduce(
      (const char *)bytes.bytes, bytes.length);
  if (raw == NULL) return nil;
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0
                                                error:nil];
  return [reply isKindOfClass:NSDictionary.class] &&
      [reply[@"ok"] isEqual:@YES] ? reply : nil;
}

static BOOL DSHStoreTextRule(NSString *op, id value) {
  if (![value isKindOfClass:NSString.class]) return NO;
  return [DSHStoreReduce(op, @{ @"value" : value })[@"valid"] isEqual:@YES];
}

static BOOL DSHStoreCanonicalId(NSString *value) {
  return DSHStoreTextRule(@"canonical_snapshot_id", value);
}

static BOOL DSHStoreSafeReferenceKey(NSString *value) {
  return DSHStoreTextRule(@"safe_reference_key", value);
}

static BOOL DSHStoreHexDigest(NSString *value) {
  return DSHStoreTextRule(@"hex_digest", value);
}

static BOOL DSHStoreExactUnsignedInteger(NSNumber *value,
                                         NSUInteger maximum,
                                         NSUInteger *output) {
  if (![value isKindOfClass:NSNumber.class] ||
      CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
    return NO;
  }
  double number = value.doubleValue;
  if (!isfinite(number) || number < 0 || floor(number) != number ||
      number > (double)maximum ||
      value.unsignedLongLongValue != (unsigned long long)number) {
    return NO;
  }
  if (output != nullptr) *output = (NSUInteger)number;
  return YES;
}

static NSString *DSHStoreSHA256(NSData *data) {
  uint8_t digest[CC_SHA256_DIGEST_LENGTH] = {};
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *hex =
      [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
  for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
    [hex appendFormat:@"%02x", digest[index]];
  }
  return hex;
}

static NSString *DSHStoreISO8601(NSDate *date) {
  NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
  formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                            NSISO8601DateFormatWithFractionalSeconds;
  formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
  return [formatter stringFromDate:date];
}

static BOOL DSHStoreEnsureDirectory(NSURL *url, NSError **error) {
  struct stat metadata = {};
  if (lstat(url.fileSystemRepresentation, &metadata) == 0) {
    if (!S_ISDIR(metadata.st_mode) || S_ISLNK(metadata.st_mode) ||
        metadata.st_nlink < 2) {
      DSHSetStoreError(error, DSHProjectContextStoreErrorUnavailable);
      return NO;
    }
  } else if (errno == ENOENT) {
    if (mkdir(url.fileSystemRepresentation, 0700) != 0) {
      DSHSetStoreError(error, DSHProjectContextStoreErrorUnavailable);
      return NO;
    }
  } else {
    DSHSetStoreError(error, DSHProjectContextStoreErrorUnavailable);
    return NO;
  }
  if (chmod(url.fileSystemRepresentation, 0700) != 0) {
    DSHSetStoreError(error, DSHProjectContextStoreErrorUnavailable);
    return NO;
  }
  [url setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
  [[NSFileManager defaultManager]
      setAttributes:@{
        NSFilePosixPermissions : @0700,
        NSFileProtectionKey : NSFileProtectionComplete,
      }
       ofItemAtPath:url.path
              error:nil];
  return YES;
}

static BOOL DSHStoreDirectoryIsSafe(NSURL *url) {
  struct stat metadata = {};
  return lstat(url.fileSystemRepresentation, &metadata) == 0 &&
         S_ISDIR(metadata.st_mode) && !S_ISLNK(metadata.st_mode);
}

static BOOL DSHStoreWriteAll(int descriptor, NSData *data) {
  const uint8_t *bytes = static_cast<const uint8_t *>(data.bytes);
  NSUInteger offset = 0;
  while (offset < data.length) {
    ssize_t count = write(descriptor, bytes + offset, data.length - offset);
    if (count <= 0) return NO;
    offset += (NSUInteger)count;
  }
  return fsync(descriptor) == 0;
}

static BOOL DSHStoreProtectFile(NSURL *url) {
  if (chmod(url.fileSystemRepresentation, 0600) != 0) return NO;
  NSError *error = nil;
  BOOL attributes = [[NSFileManager defaultManager]
      setAttributes:@{
        NSFilePosixPermissions : @0600,
        NSFileProtectionKey : NSFileProtectionComplete,
      }
       ofItemAtPath:url.path
              error:&error];
  BOOL excluded =
      [url setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:&error];
  return attributes && excluded;
}

@interface DSHProjectContextStore ()
@property(nonatomic, strong, readwrite) NSURL *rootURL;
@property(nonatomic, strong) NSURL *snapshotsURL;
@property(nonatomic, strong) NSURL *consentsURL;
@property(nonatomic) NSUInteger capacityBytes;
@property(nonatomic, copy) DSHProjectContextClock clock;
@property(nonatomic, copy) DSHProjectContextIdentifierGenerator identifierGenerator;
@property(nonatomic, strong) NSRecursiveLock *lock;
@property(nonatomic) BOOL didReconcile;
- (nullable NSDictionary *)references:(NSError **)error;
- (BOOL)writeReferences:(NSDictionary *)references error:(NSError **)error;
- (BOOL)writeReferences:(NSDictionary *)references
                 applied:(BOOL *_Nullable)applied
                   error:(NSError **)error;
- (BOOL)replaceData:(NSData *)data
               atURL:(NSURL *)destination
             applied:(BOOL *_Nullable)applied
               error:(NSError **)error;
- (nullable NSDictionary *)accesses:(NSError **)error;
- (BOOL)writeAccesses:(NSDictionary *)accesses error:(NSError **)error;
- (NSUInteger)storageBytes;
- (NSUInteger)snapshotArtifactBytes:(NSString *)snapshotId;
- (BOOL)reconcileStorage:(NSError **)error;
- (BOOL)pruneUnreferencedSnapshotsExcept:(nullable NSString *)snapshotId
                                    error:(NSError **)error;
- (nullable NSDictionary *)newConsentReceiptForSnapshotId:(NSString *)snapshotId
                                            snapshotDigest:(NSString *)snapshotDigest
                                                storedData:(NSData **)storedData
                                                     error:(NSError **)error;
@end

static NSRecursiveLock *DSHStoreLockForRoot(NSURL *rootURL) {
  static NSMutableDictionary<NSString *, NSRecursiveLock *> *locks;
  static NSLock *guard;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    locks = [NSMutableDictionary dictionary];
    guard = [[NSLock alloc] init];
  });
  NSString *key = rootURL.path.stringByStandardizingPath ?: @"<invalid>";
  [guard lock];
  NSRecursiveLock *lock = locks[key];
  if (lock == nil) {
    lock = [[NSRecursiveLock alloc] init];
    locks[key] = lock;
  }
  [guard unlock];
  return lock;
}

@implementation DSHProjectContextStore

- (instancetype)init {
  NSError *error = nil;
  NSURL *support = [[NSFileManager defaultManager]
      URLForDirectory:NSApplicationSupportDirectory
             inDomain:NSUserDomainMask
    appropriateForURL:nil
               create:YES
                error:&error];
  NSURL *root =
      [support URLByAppendingPathComponent:@"project-context" isDirectory:YES];
  return [self initWithRootURL:root
                 capacityBytes:DSHProjectContextStoreDefaultCapacityBytes
                         clock:^NSDate * {
                           return NSDate.date;
                         }
           identifierGenerator:^NSString * {
             return NSUUID.UUID.UUIDString.lowercaseString;
           }];
}

- (instancetype)initWithRootURL:(NSURL *)rootURL
                   capacityBytes:(NSUInteger)capacityBytes
                           clock:(DSHProjectContextClock)clock
             identifierGenerator:
                 (DSHProjectContextIdentifierGenerator)identifierGenerator {
  self = [super init];
  if (self) {
    _rootURL = [rootURL copy];
    _snapshotsURL = [_rootURL URLByAppendingPathComponent:@"snapshots"
                                              isDirectory:YES];
    _consentsURL = [_rootURL URLByAppendingPathComponent:@"consents"
                                             isDirectory:YES];
    _capacityBytes = capacityBytes;
    _clock = [clock copy];
    _identifierGenerator = [identifierGenerator copy];
    _lock = DSHStoreLockForRoot(_rootURL);
  }
  return self;
}

- (BOOL)ensureStorage:(NSError **)error {
  if (self.rootURL == nil || self.capacityBytes == 0 || self.clock == nil ||
      self.identifierGenerator == nil) {
    DSHSetStoreError(error, DSHProjectContextStoreErrorInvalidArgument);
    return NO;
  }
  NSURL *parent = self.rootURL.URLByDeletingLastPathComponent;
  if (!DSHStoreDirectoryIsSafe(parent)) {
    DSHSetStoreError(error, DSHProjectContextStoreErrorUnavailable);
    return NO;
  }
  if (!DSHStoreEnsureDirectory(self.rootURL, error) ||
      !DSHStoreEnsureDirectory(self.snapshotsURL, error) ||
      !DSHStoreEnsureDirectory(self.consentsURL, error)) {
    return NO;
  }
  if (!self.didReconcile) {
    self.didReconcile = YES;
    if (![self reconcileStorage:error]) {
      self.didReconcile = NO;
      return NO;
    }
  }
  return YES;
}

- (NSURL *)envelopeURL:(NSString *)snapshotId {
  return [self.snapshotsURL
      URLByAppendingPathComponent:[snapshotId stringByAppendingString:@".envelope"]];
}

- (NSURL *)recordURL:(NSString *)snapshotId {
  return [self.snapshotsURL
      URLByAppendingPathComponent:[snapshotId stringByAppendingString:@".json"]];
}

- (NSURL *)consentURL:(NSString *)receiptId {
  return [self.consentsURL
      URLByAppendingPathComponent:[receiptId stringByAppendingString:@".json"]];
}

- (NSURL *)referencesURL {
  return [self.rootURL URLByAppendingPathComponent:@"references.json"];
}

- (NSURL *)accessesURL {
  return [self.rootURL URLByAppendingPathComponent:@"accesses.json"];
}

static BOOL DSHUnlinkURLIfPresent(NSURL *url) {
  if (unlink(url.fileSystemRepresentation) == 0) return YES;
  return errno == ENOENT;
}

- (BOOL)reconcileStorage:(NSError **)error {
  NSError *enumerationError = nil;
  NSMutableSet<NSString *> *snapshotIds = [NSMutableSet set];
  NSArray<NSURL *> *snapshotFiles = [[NSFileManager defaultManager]
      contentsOfDirectoryAtURL:self.snapshotsURL
    includingPropertiesForKeys:nil options:0 error:&enumerationError];
  if (snapshotFiles == nil) {
    DSHSetStoreError(error, DSHProjectContextStoreErrorUnavailable);
    return NO;
  }
  NSMutableArray<NSURL *> *cleanupSnapshotFiles = [NSMutableArray array];
  for (NSURL *url in snapshotFiles) {
    NSString *name = url.lastPathComponent;
    if ([name hasPrefix:@"."]) {
      [cleanupSnapshotFiles addObject:url];
      continue;
    }
    NSString *snapshotId = name.stringByDeletingPathExtension;
    if (DSHStoreCanonicalId(snapshotId) &&
        ([url.pathExtension isEqual:@"json"] ||
         [url.pathExtension isEqual:@"envelope"])) {
      [snapshotIds addObject:snapshotId];
    } else {
      [cleanupSnapshotFiles addObject:url];
    }
  }
  NSMutableSet<NSString *> *validIds = [NSMutableSet set];
  NSMutableSet<NSString *> *corruptIds = [NSMutableSet set];
  for (NSString *snapshotId in snapshotIds) {
    NSError *recordError = nil;
    NSDictionary *record = [self loadRecordSnapshotId:snapshotId
                                                 error:&recordError];
    if (record == nil && recordError.code != DSHProjectContextStoreErrorIntegrity &&
        recordError.code != DSHProjectContextStoreErrorNotFound) {
      DSHSetStoreError(error, DSHProjectContextStoreErrorUnavailable);
      return NO;
    }
    NSUInteger length = [record[@"envelope_bytes"] unsignedIntegerValue];
    NSError *envelopeError = nil;
    NSData *envelope = record == nil ? nil :
        [self readProtectedFile:[self envelopeURL:snapshotId]
                       maxLength:length error:&envelopeError];
    if (record != nil && envelope == nil &&
        envelopeError.code != DSHProjectContextStoreErrorIntegrity &&
        envelopeError.code != DSHProjectContextStoreErrorNotFound) {
      DSHSetStoreError(error, DSHProjectContextStoreErrorUnavailable);
      return NO;
    }
    BOOL valid = record != nil && envelope.length == length &&
        [DSHStoreSHA256(envelope) isEqual:record[@"snapshot_sha256"]];
    if (valid) {
      [validIds addObject:snapshotId];
    } else {
      [corruptIds addObject:snapshotId];
    }
  }

  enumerationError = nil;
  NSArray<NSURL *> *consentFiles = [[NSFileManager defaultManager]
      contentsOfDirectoryAtURL:self.consentsURL
    includingPropertiesForKeys:nil options:0 error:&enumerationError];
  if (consentFiles == nil) {
    DSHSetStoreError(error, DSHProjectContextStoreErrorUnavailable);
    return NO;
  }
  NSMutableArray<NSURL *> *cleanupConsentFiles = [NSMutableArray array];
  for (NSURL *url in consentFiles) {
    NSString *receiptId = url.lastPathComponent.stringByDeletingPathExtension;
    NSError *receiptError = nil;
    NSDictionary *receipt = DSHStoreCanonicalId(receiptId) ?
        [self loadConsentReceiptId:receiptId error:&receiptError] : nil;
    if (DSHStoreCanonicalId(receiptId) && receipt == nil &&
        receiptError.code != DSHProjectContextStoreErrorIntegrity &&
        receiptError.code != DSHProjectContextStoreErrorNotFound) {
      DSHSetStoreError(error, DSHProjectContextStoreErrorUnavailable);
      return NO;
    }
    if (receipt == nil ||
        ![validIds containsObject:receipt[@"snapshot_id"]]) {
      [cleanupConsentFiles addObject:url];
    }
  }

  NSError *stateError = nil;
  NSDictionary *storedReferences = [self references:&stateError];
  if (storedReferences == nil) {
    DSHSetStoreError(error, DSHProjectContextStoreErrorUnavailable);
    return NO;
  }
  NSMutableDictionary *references = [storedReferences mutableCopy];
  NSMutableSet<NSString *> *transactionNewIds = [NSMutableSet set];
  for (NSString *key in references.allKeys) {
    if (![key hasPrefix:@"txn:prepare:"]) continue;
    NSString *conversation = [key substringFromIndex:@"txn:prepare:".length];
    NSString *activeKey = [@"active:" stringByAppendingString:conversation];
    NSString *newSnapshotId = references[activeKey];
    NSString *rollbackSnapshotId = references[key];
    if (DSHStoreCanonicalId(newSnapshotId)) {
      BOOL crashBeforeSwap = [newSnapshotId isEqual:rollbackSnapshotId] &&
          ![rollbackSnapshotId isEqual:DSHPrepareNoPriorSnapshotId];
      if (!crashBeforeSwap) {
        if (![rollbackSnapshotId isEqual:DSHPrepareNoPriorSnapshotId] &&
            [validIds containsObject:rollbackSnapshotId]) {
          references[activeKey] = rollbackSnapshotId;
        } else {
          [references removeObjectForKey:activeKey];
        }
        [transactionNewIds addObject:newSnapshotId];
      }
    }
    [references removeObjectForKey:key];
  }
  for (NSString *key in references.allKeys) {
    BOOL permitted = [key hasPrefix:@"active:"] || [key hasPrefix:@"retry:"];
    if (!permitted || ![validIds containsObject:references[key]]) {
      [references removeObjectForKey:key];
    }
  }
  NSSet<NSString *> *referencedIds = [NSSet setWithArray:references.allValues];
  NSMutableSet<NSString *> *orphanIds = [validIds mutableCopy];
  [orphanIds minusSet:referencedIds];
  [orphanIds unionSet:transactionNewIds];
  [validIds minusSet:orphanIds];
  stateError = nil;
  NSDictionary *storedAccesses = [self accesses:&stateError];
  if (storedAccesses == nil) {
    DSHSetStoreError(error, DSHProjectContextStoreErrorUnavailable);
    return NO;
  }
  NSMutableDictionary *accesses = [storedAccesses mutableCopy];
  for (NSString *snapshotId in accesses.allKeys) {
    if (![validIds containsObject:snapshotId]) {
      [accesses removeObjectForKey:snapshotId];
    }
  }
  for (NSURL *url in consentFiles) {
    NSString *receiptId = url.lastPathComponent.stringByDeletingPathExtension;
    NSDictionary *receipt = DSHStoreCanonicalId(receiptId)
        ? [self loadConsentReceiptId:receiptId error:nil] : nil;
    if (receipt != nil && [orphanIds containsObject:receipt[@"snapshot_id"]] &&
        ![cleanupConsentFiles containsObject:url]) {
      [cleanupConsentFiles addObject:url];
    }
  }
  BOOL success = YES;
  success = [self writeReferences:references error:error] && success;
  success = [self writeAccesses:accesses error:error] && success;
  if (!success) {
    DSHSetStoreError(error, DSHProjectContextStoreErrorUnavailable);
    return NO;
  }
  for (NSURL *url in cleanupSnapshotFiles) {
    success = DSHUnlinkURLIfPresent(url) && success;
  }
  for (NSString *snapshotId in corruptIds) {
    success = DSHUnlinkURLIfPresent([self recordURL:snapshotId]) && success;
    success = DSHUnlinkURLIfPresent([self envelopeURL:snapshotId]) && success;
  }
  for (NSString *snapshotId in orphanIds) {
    success = DSHUnlinkURLIfPresent([self recordURL:snapshotId]) && success;
    success = DSHUnlinkURLIfPresent([self envelopeURL:snapshotId]) && success;
  }
  for (NSURL *url in cleanupConsentFiles) {
    success = DSHUnlinkURLIfPresent(url) && success;
  }
  if (success && [self storageBytes] > self.capacityBytes) {
    NSError *capacityError = nil;
    if (![self pruneWithProtectedSnapshotId:nil error:&capacityError] &&
        capacityError.code != DSHProjectContextStoreErrorCapacity) {
      success = NO;
      if (error != nil) *error = capacityError;
    }
  }

  for (NSURL *directoryURL in @[self.snapshotsURL, self.consentsURL,
                                self.rootURL]) {
    int descriptor = open(directoryURL.fileSystemRepresentation,
                          O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0 || fsync(descriptor) != 0) success = NO;
    if (descriptor >= 0) close(descriptor);
  }
  if (!success) {
    DSHSetStoreError(error, DSHProjectContextStoreErrorUnavailable);
  }
  return success;
}

- (BOOL)publishImmutableData:(NSData *)data
                       toURL:(NSURL *)destination
                       error:(NSError **)error {
  NSString *temporaryName =
      [NSString stringWithFormat:@".%@.%@.tmp", destination.lastPathComponent,
                                 NSUUID.UUID.UUIDString.lowercaseString];
  NSURL *temporary =
      [destination.URLByDeletingLastPathComponent
          URLByAppendingPathComponent:temporaryName];
  int descriptor = open(temporary.fileSystemRepresentation,
                        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
  BOOL success = descriptor >= 0 && DSHStoreWriteAll(descriptor, data);
  if (descriptor >= 0) close(descriptor);
  success = success && DSHStoreProtectFile(temporary);
  if (success) {
    success = link(temporary.fileSystemRepresentation,
                   destination.fileSystemRepresentation) == 0;
  }
  unlink(temporary.fileSystemRepresentation);
  if (success) {
    success = DSHStoreProtectFile(destination);
    int directory = open(destination.URLByDeletingLastPathComponent
                             .fileSystemRepresentation,
                         O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (directory >= 0) {
      success = fsync(directory) == 0 && success;
      close(directory);
    } else {
      success = NO;
    }
  }
  if (!success) {
    DSHSetStoreError(error, errno == EEXIST
                                ? DSHProjectContextStoreErrorInvalidArgument
                                : DSHProjectContextStoreErrorUnavailable);
  }
  return success;
}

- (BOOL)replaceData:(NSData *)data
               atURL:(NSURL *)destination
               error:(NSError **)error {
  return [self replaceData:data atURL:destination applied:nil error:error];
}

- (BOOL)replaceData:(NSData *)data
               atURL:(NSURL *)destination
             applied:(BOOL *)applied
               error:(NSError **)error {
  if (applied != nullptr) *applied = NO;
  NSString *temporaryName =
      [NSString stringWithFormat:@".%@.%@.tmp", destination.lastPathComponent,
                                 NSUUID.UUID.UUIDString.lowercaseString];
  NSURL *temporary =
      [destination.URLByDeletingLastPathComponent
          URLByAppendingPathComponent:temporaryName];
  int descriptor = open(temporary.fileSystemRepresentation,
                        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
  BOOL success = descriptor >= 0 && DSHStoreWriteAll(descriptor, data);
  if (descriptor >= 0) close(descriptor);
  success = success && DSHStoreProtectFile(temporary);
  if (success) {
    BOOL renamed = rename(temporary.fileSystemRepresentation,
                          destination.fileSystemRepresentation) == 0;
    if (renamed && applied != nullptr) *applied = YES;
    success = renamed;
  }
  if (!success) unlink(temporary.fileSystemRepresentation);
  if (success) {
    success = DSHStoreProtectFile(destination);
    int directory = open(destination.URLByDeletingLastPathComponent
                             .fileSystemRepresentation,
                         O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (directory >= 0) {
      success = fsync(directory) == 0 && success;
      close(directory);
    } else {
      success = NO;
    }
  }
  if (!success) {
    DSHSetStoreError(error, DSHProjectContextStoreErrorUnavailable);
  }
  return success;
}

- (NSData *)readProtectedFile:(NSURL *)url
                    maxLength:(NSUInteger)maxLength
                        error:(NSError **)error {
  int descriptor = open(url.fileSystemRepresentation,
                        O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (descriptor < 0) {
    DSHSetStoreError(error, errno == ENOENT
                                ? DSHProjectContextStoreErrorNotFound
                                : DSHProjectContextStoreErrorUnavailable);
    return nil;
  }
  struct stat before = {};
  BOOL valid = fstat(descriptor, &before) == 0 && S_ISREG(before.st_mode) &&
               before.st_nlink == 1 && before.st_size >= 0 &&
               (NSUInteger)before.st_size <= maxLength &&
               (before.st_mode & 0777) == 0600;
  NSMutableData *data = valid
                            ? [NSMutableData dataWithLength:(NSUInteger)before.st_size]
                            : nil;
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
          before.st_dev == after.st_dev && before.st_ino == after.st_ino &&
          before.st_mode == after.st_mode && before.st_nlink == after.st_nlink &&
          before.st_size == after.st_size &&
          before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec &&
          before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
          before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec &&
          before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec;
  close(descriptor);
  if (!valid) {
    DSHSetStoreError(error, DSHProjectContextStoreErrorIntegrity);
    return nil;
  }
  return [data copy];
}

static BOOL DSHStoreDictionaryHasExactKeys(NSDictionary *object,
                                           NSSet<NSString *> *keys) {
  if (![object isKindOfClass:NSDictionary.class] || object.count != keys.count) {
    return NO;
  }
  for (id key in object) {
    if (![key isKindOfClass:NSString.class] || ![keys containsObject:key]) {
      return NO;
    }
  }
  return YES;
}

- (BOOL)saveEnvelope:(NSData *)envelope
             manifest:(NSDictionary *)manifest
      sourceDescriptor:(NSDictionary *)sourceDescriptor
           snapshotId:(NSString *)snapshotId
                error:(NSError **)error {
  return [self saveEnvelope:envelope
                   manifest:manifest
            sourceDescriptor:sourceDescriptor
                 snapshotId:snapshotId
         activeReferenceKey:nil
                      error:error];
}

- (BOOL)saveEnvelope:(NSData *)envelope
             manifest:(NSDictionary *)manifest
      sourceDescriptor:(NSDictionary *)sourceDescriptor
           snapshotId:(NSString *)snapshotId
   activeReferenceKey:(NSString *)activeReferenceKey
                error:(NSError **)error {
  [self.lock lock];
  BOOL success = NO;
  @try {
    NSString *digest = [manifest[@"snapshot_sha256"] isKindOfClass:NSString.class]
                           ? manifest[@"snapshot_sha256"]
                           : nil;
    NSString *fingerprint =
        [manifest[@"source_fingerprint"] isKindOfClass:NSString.class]
            ? manifest[@"source_fingerprint"]
            : nil;
    if (![envelope isKindOfClass:NSData.class] || envelope.length == 0 ||
        ![manifest isKindOfClass:NSDictionary.class] ||
        ![sourceDescriptor isKindOfClass:NSDictionary.class] ||
        !DSHStoreCanonicalId(snapshotId) || !DSHStoreHexDigest(digest) ||
        ![digest isEqualToString:DSHStoreSHA256(envelope)] ||
        fingerprint.length == 0 || fingerprint.length > 512 ||
        (activeReferenceKey != nil &&
         !DSHStoreSafeReferenceKey(activeReferenceKey)) ||
        (manifest[@"snapshot_id"] != nil &&
         ![manifest[@"snapshot_id"] isEqual:snapshotId])) {
      DSHSetStoreError(error, DSHProjectContextStoreErrorInvalidArgument);
      return NO;
    }
    if (![self ensureStorage:error]) return NO;
    NSDictionary *previousReferences = activeReferenceKey == nil
        ? nil
        : [self references:error];
    if (activeReferenceKey != nil && previousReferences == nil) return NO;
    NSString *timestamp = DSHStoreISO8601(self.clock());
    NSDictionary *previousAccesses = [self accesses:error];
    if (previousAccesses == nil) return NO;
    NSDictionary *recordCore = @{
      @"schema_version" : @1,
      @"snapshot_id" : snapshotId,
      @"snapshot_sha256" : digest,
      @"envelope_bytes" : @(envelope.length),
      @"created_at" : timestamp,
      @"last_accessed_at" : timestamp,
      @"manifest" : manifest,
      @"source_descriptor" : sourceDescriptor,
    };
    NSMutableDictionary *record = [recordCore mutableCopy];
    record[@"record_sha256"] =
        DSHStoreSHA256([NSJSONSerialization dataWithJSONObject:recordCore
                                                       options:NSJSONWritingSortedKeys
                                                         error:nil]);
    NSData *recordData = [NSJSONSerialization dataWithJSONObject:record
                                                          options:NSJSONWritingSortedKeys
                                                            error:nil];
    if (recordData == nil || recordData.length > DSHStoreMaxRecordBytes) {
      DSHSetStoreError(error, DSHProjectContextStoreErrorInvalidArgument);
      return NO;
    }
    NSURL *envelopeURL = [self envelopeURL:snapshotId];
    NSURL *recordURL = [self recordURL:snapshotId];
    if (![self publishImmutableData:envelope toURL:envelopeURL error:error]) {
      return NO;
    }
    if (![self publishImmutableData:recordData toURL:recordURL error:error]) {
      unlink(envelopeURL.fileSystemRepresentation);
      return NO;
    }
    NSMutableDictionary *updatedAccesses = [previousAccesses mutableCopy];
    updatedAccesses[snapshotId] = timestamp;
    if (![self writeAccesses:updatedAccesses error:error]) {
      unlink(recordURL.fileSystemRepresentation);
      unlink(envelopeURL.fileSystemRepresentation);
      return NO;
    }
    void (^rollbackNewSnapshot)(void) = ^{
      NSMutableDictionary *rollbackAccesses =
          [[self accesses:nil] mutableCopy] ?: [previousAccesses mutableCopy];
      [rollbackAccesses removeObjectForKey:snapshotId];
      [self writeAccesses:rollbackAccesses error:nil];
      unlink(recordURL.fileSystemRepresentation);
      unlink(envelopeURL.fileSystemRepresentation);
      int snapshots = open(self.snapshotsURL.fileSystemRepresentation,
                           O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
      if (snapshots >= 0) {
        fsync(snapshots);
        close(snapshots);
      }
    };
    NSString *oldActive = activeReferenceKey == nil
                              ? nil
                              : previousReferences[activeReferenceKey];
    if (activeReferenceKey != nil) {
      NSMutableDictionary *updatedReferences = [previousReferences mutableCopy];
      updatedReferences[activeReferenceKey] = snapshotId;
      if (![self pruneUnreferencedSnapshotsExcept:snapshotId error:error]) {
        rollbackNewSnapshot();
        return NO;
      }
      NSData *referenceData = [NSJSONSerialization
          dataWithJSONObject:updatedReferences
                     options:NSJSONWritingSortedKeys
                       error:nil];
      NSNumber *referenceSize = nil;
      [[self referencesURL] getResourceValue:&referenceSize
                                      forKey:NSURLFileSizeKey error:nil];
      NSUInteger currentReferenceBytes = referenceSize.unsignedIntegerValue;
      NSUInteger total = [self storageBytes];
      BOOL oldCanPrune = oldActive != nil &&
          ![oldActive isEqual:snapshotId] &&
          ![updatedReferences.allValues containsObject:oldActive];
      NSUInteger oldBytes = oldCanPrune
          ? [self snapshotArtifactBytes:oldActive]
          : 0;
      NSUInteger projected = referenceData == nil || total < currentReferenceBytes
          ? NSUIntegerMax
          : total - currentReferenceBytes + referenceData.length;
      if (oldCanPrune) {
        projected = oldBytes == 0 || projected < oldBytes
            ? NSUIntegerMax
            : projected - oldBytes;
      }
      if (referenceData == nil ||
          referenceData.length > DSHStoreMaxReferenceBytes ||
          projected > self.capacityBytes) {
        DSHSetStoreError(error, DSHProjectContextStoreErrorCapacity);
        rollbackNewSnapshot();
        return NO;
      }
      if (![self writeReferences:updatedReferences error:error]) {
        rollbackNewSnapshot();
        return NO;
      }
      if (oldCanPrune && ![self discardSnapshotId:oldActive error:error]) {
        BOOL oldStillPresent =
            [[NSFileManager defaultManager]
                fileExistsAtPath:[self recordURL:oldActive].path] &&
            [[NSFileManager defaultManager]
                fileExistsAtPath:[self envelopeURL:oldActive].path];
        if (oldStillPresent) {
          [self writeReferences:previousReferences error:nil];
          rollbackNewSnapshot();
        }
        return NO;
      }
    } else if (![self pruneWithProtectedSnapshotId:snapshotId error:error]) {
      rollbackNewSnapshot();
      return NO;
    }
    success = [[NSFileManager defaultManager] fileExistsAtPath:recordURL.path];
    if (!success) {
      DSHSetStoreError(error, DSHProjectContextStoreErrorCapacity);
    }
  } @finally {
    [self.lock unlock];
  }
  return success;
}

static NSString *DSHPrepareTransactionKey(NSString *activeReferenceKey) {
  if (![activeReferenceKey isKindOfClass:NSString.class]) return nil;
  id key = DSHStoreReduce(@"prepare_transaction_key", @{
    @"active_key" : activeReferenceKey,
  })[@"key"];
  return [key isKindOfClass:NSString.class] ? key : nil;
}

- (BOOL)beginPrepareTransactionWithEnvelope:(NSData *)envelope
                                    manifest:(NSDictionary *)manifest
                             sourceDescriptor:(NSDictionary *)sourceDescriptor
                                  snapshotId:(NSString *)snapshotId
                           activeReferenceKey:(NSString *)activeReferenceKey
                                       error:(NSError **)error {
  [self.lock lock];
  @try {
    NSString *transactionKey = DSHPrepareTransactionKey(activeReferenceKey);
    if (transactionKey == nil || !DSHStoreCanonicalId(snapshotId) ||
        ![self ensureStorage:error]) {
      DSHSetStoreError(error, DSHProjectContextStoreErrorInvalidArgument);
      return NO;
    }
    NSDictionary *references = [self references:error];
    if (references == nil) return NO;
    NSString *existingTransaction = references[transactionKey];
    NSString *existingActive = references[activeReferenceKey];
    if (existingTransaction != nil) {
      if (existingActive != nil) {
        if (![self abortPrepareTransactionForSnapshotId:existingActive
                                      activeReferenceKey:activeReferenceKey
                                                   error:error]) {
          return NO;
        }
      } else {
        NSMutableDictionary *cleared = [references mutableCopy];
        [cleared removeObjectForKey:transactionKey];
        if (![self writeReferences:cleared error:error]) return NO;
      }
    }
    references = [self references:error];
    if (references == nil || references[transactionKey] != nil) return NO;
    NSString *previousActive = references[activeReferenceKey];
    NSMutableDictionary *transactionReferences = [references mutableCopy];
    transactionReferences[transactionKey] =
        previousActive ?: DSHPrepareNoPriorSnapshotId;
    if (![self writeReferences:transactionReferences error:error]) return NO;
    if (![self saveEnvelope:envelope manifest:manifest
              sourceDescriptor:sourceDescriptor snapshotId:snapshotId
            activeReferenceKey:activeReferenceKey error:error]) {
      if (![self writeReferences:references error:nil]) {
        DSHSetStoreError(error, DSHProjectContextStoreErrorUnavailable);
      }
      return NO;
    }
    return YES;
  } @finally {
    [self.lock unlock];
  }
}

- (BOOL)abortPrepareTransactionForSnapshotId:(NSString *)snapshotId
                           activeReferenceKey:(NSString *)activeReferenceKey
                                        error:(NSError **)error {
  [self.lock lock];
  @try {
    NSString *transactionKey = DSHPrepareTransactionKey(activeReferenceKey);
    if (transactionKey == nil || !DSHStoreCanonicalId(snapshotId) ||
        ![self ensureStorage:error]) {
      DSHSetStoreError(error, DSHProjectContextStoreErrorInvalidArgument);
      return NO;
    }
    NSDictionary *references = [self references:error];
    NSString *rollbackSnapshot = references[transactionKey];
    if (references == nil || rollbackSnapshot == nil ||
        ![references[activeReferenceKey] isEqual:snapshotId]) {
      DSHSetStoreError(error, DSHProjectContextStoreErrorNotFound);
      return NO;
    }
    NSMutableDictionary *updated = [references mutableCopy];
    [updated removeObjectForKey:transactionKey];
    if ([rollbackSnapshot isEqual:DSHPrepareNoPriorSnapshotId]) {
      [updated removeObjectForKey:activeReferenceKey];
    } else if ([self loadRecordSnapshotId:rollbackSnapshot error:nil] != nil) {
      updated[activeReferenceKey] = rollbackSnapshot;
    } else {
      [updated removeObjectForKey:activeReferenceKey];
    }
    BOOL referencesApplied = NO;
    if (![self writeReferences:updated applied:&referencesApplied error:error]) {
      if (referencesApplied) self.didReconcile = NO;
      return NO;
    }
    if (![updated.allValues containsObject:snapshotId]) {
      if (![self discardSnapshotId:snapshotId error:nil]) {
        self.didReconcile = NO;
      }
    }
    return YES;
  } @finally {
    [self.lock unlock];
  }
}

- (NSDictionary *)
    commitPrepareTransactionForSnapshotId:(NSString *)snapshotId
                        activeReferenceKey:(NSString *)activeReferenceKey
                            snapshotDigest:(NSString *)snapshotDigest
                                     error:(NSError **)error {
  [self.lock lock];
  @try {
    NSString *transactionKey = DSHPrepareTransactionKey(activeReferenceKey);
    if (transactionKey == nil || !DSHStoreCanonicalId(snapshotId) ||
        !DSHStoreHexDigest(snapshotDigest) || ![self ensureStorage:error]) {
      DSHSetStoreError(error, DSHProjectContextStoreErrorInvalidArgument);
      return nil;
    }
    NSDictionary *references = [self references:error];
    NSDictionary *snapshot = [self loadSnapshotId:snapshotId error:error];
    if (references == nil || references[transactionKey] == nil ||
        ![references[activeReferenceKey] isEqual:snapshotId] || snapshot == nil ||
        ![snapshot[@"manifest"][@"snapshot_sha256"] isEqual:snapshotDigest]) {
      DSHSetStoreError(error, DSHProjectContextStoreErrorNotFound);
      return nil;
    }
    NSMutableDictionary *updated = [references mutableCopy];
    [updated removeObjectForKey:transactionKey];
    if (![self pruneUnreferencedSnapshotsExcept:snapshotId error:error]) {
      return nil;
    }
    NSData *receiptData = nil;
    NSDictionary *receipt = [self newConsentReceiptForSnapshotId:snapshotId
                                                   snapshotDigest:snapshotDigest
                                                       storedData:&receiptData
                                                            error:error];
    NSData *referenceData = [NSJSONSerialization
        dataWithJSONObject:updated options:NSJSONWritingSortedKeys error:nil];
    NSNumber *currentReferenceSize = nil;
    [[self referencesURL] getResourceValue:&currentReferenceSize
                                    forKey:NSURLFileSizeKey error:nil];
    NSUInteger currentBytes = [self storageBytes];
    NSUInteger referenceBytes = currentReferenceSize.unsignedIntegerValue;
    NSString *rollbackSnapshot = references[transactionKey];
    BOOL reclaimRollback = DSHStoreCanonicalId(rollbackSnapshot) &&
        ![updated.allValues containsObject:rollbackSnapshot];
    NSUInteger reclaimBytes = reclaimRollback
        ? [self snapshotArtifactBytes:rollbackSnapshot] : 0;
    NSUInteger projected = receipt == nil || referenceData == nil ||
            currentBytes < referenceBytes
        ? NSUIntegerMax
        : currentBytes - referenceBytes + referenceData.length +
              receiptData.length;
    if (reclaimBytes > 0) {
      projected = projected < reclaimBytes
          ? NSUIntegerMax : projected - reclaimBytes;
    }
    if (receipt == nil || referenceData.length > DSHStoreMaxReferenceBytes ||
        projected > self.capacityBytes) {
      if (receipt != nil) {
        DSHSetStoreError(error, DSHProjectContextStoreErrorCapacity);
      }
      return nil;
    }
    NSURL *consentURL = [self consentURL:receipt[@"consent_receipt_id"]];
    if (![self publishImmutableData:receiptData toURL:consentURL error:error]) {
      self.didReconcile = NO;
      return nil;
    }
    BOOL referencesApplied = NO;
    if (![self writeReferences:updated applied:&referencesApplied error:error]) {
      if (referencesApplied) {
        self.didReconcile = NO;
        return nil;
      }
      BOOL removed = DSHUnlinkURLIfPresent(consentURL);
      int consentsDescriptor = open(self.consentsURL.fileSystemRepresentation,
                                    O_RDONLY | O_DIRECTORY | O_CLOEXEC |
                                        O_NOFOLLOW);
      BOOL synced = consentsDescriptor >= 0 && fsync(consentsDescriptor) == 0;
      if (consentsDescriptor >= 0) close(consentsDescriptor);
      if (!removed || !synced) {
        self.didReconcile = NO;
        DSHSetStoreError(error, DSHProjectContextStoreErrorUnavailable);
      }
      return nil;
    }
    if (reclaimRollback) {
      if (![self discardSnapshotId:rollbackSnapshot error:nil]) {
        self.didReconcile = NO;
      }
    }
    return receipt;
  } @finally {
    [self.lock unlock];
  }
}

- (NSDictionary *)loadRecordSnapshotId:(NSString *)snapshotId
                                  error:(NSError **)error {
  NSData *recordData = [self readProtectedFile:[self recordURL:snapshotId]
                                     maxLength:DSHStoreMaxRecordBytes
                                         error:error];
  NSDictionary *record = recordData == nil
                             ? nil
                             : [NSJSONSerialization JSONObjectWithData:recordData
                                                               options:0
                                                                 error:nil];
  if (![record isKindOfClass:NSDictionary.class]) {
    if (recordData != nil) {
      DSHSetStoreError(error, DSHProjectContextStoreErrorIntegrity);
    }
    return nil;
  }
  NSSet *keys = [NSSet setWithArray:@[
    @"schema_version", @"snapshot_id", @"snapshot_sha256", @"envelope_bytes",
    @"created_at", @"last_accessed_at", @"manifest", @"source_descriptor",
    @"record_sha256"
  ]];
  NSNumber *length = [record[@"envelope_bytes"] isKindOfClass:NSNumber.class]
                         ? record[@"envelope_bytes"]
                         : nil;
  NSUInteger exactLength = 0;
  NSMutableDictionary *recordCore = [record mutableCopy];
  NSString *recordDigest = [recordCore[@"record_sha256"]
      isKindOfClass:NSString.class] ? recordCore[@"record_sha256"] : nil;
  [recordCore removeObjectForKey:@"record_sha256"];
  NSData *recordCoreData = [NSJSONSerialization dataWithJSONObject:recordCore
                                                            options:NSJSONWritingSortedKeys
                                                              error:nil];
  NSDictionary *manifest = record[@"manifest"];
  NSDictionary *source = record[@"source_descriptor"];
  if (!DSHStoreDictionaryHasExactKeys(record, keys) ||
      ![record[@"schema_version"] isEqual:@1] ||
      ![record[@"snapshot_id"] isEqual:snapshotId] ||
      !DSHStoreHexDigest(record[@"snapshot_sha256"]) ||
      !DSHStoreHexDigest(recordDigest) || recordCoreData == nil ||
      ![recordDigest isEqual:DSHStoreSHA256(recordCoreData)] ||
      ![manifest isKindOfClass:NSDictionary.class] ||
      ![source isKindOfClass:NSDictionary.class] ||
      (manifest[@"snapshot_id"] != nil &&
       ![manifest[@"snapshot_id"] isEqual:snapshotId]) ||
      ![manifest[@"snapshot_sha256"] isEqual:record[@"snapshot_sha256"]] ||
      (manifest[@"project_id"] != nil && source[@"project_id"] != nil &&
       ![manifest[@"project_id"] isEqual:source[@"project_id"]]) ||
      (manifest[@"source_fingerprint"] != nil &&
       source[@"source_fingerprint"] != nil &&
       ![manifest[@"source_fingerprint"]
           isEqual:source[@"source_fingerprint"]]) ||
      !DSHStoreExactUnsignedInteger(length,
                                    DSHProjectContextStoreDefaultCapacityBytes,
                                    &exactLength) ||
      exactLength == 0 ||
      ![record[@"created_at"] isKindOfClass:NSString.class] ||
      ![record[@"last_accessed_at"] isKindOfClass:NSString.class]) {
    DSHSetStoreError(error, DSHProjectContextStoreErrorIntegrity);
    return nil;
  }
  return record;
}

- (NSDictionary *)loadSnapshotId:(NSString *)snapshotId
                            error:(NSError **)error {
  [self.lock lock];
  @try {
    if (!DSHStoreCanonicalId(snapshotId) || ![self ensureStorage:error]) {
      if (!DSHStoreCanonicalId(snapshotId)) {
        DSHSetStoreError(error, DSHProjectContextStoreErrorInvalidArgument);
      }
      return nil;
    }
    NSDictionary *record = [self loadRecordSnapshotId:snapshotId error:error];
    if (record == nil) return nil;
    NSUInteger length = [record[@"envelope_bytes"] unsignedIntegerValue];
    NSData *envelope = [self readProtectedFile:[self envelopeURL:snapshotId]
                                     maxLength:length
                                         error:error];
    if (envelope.length != length ||
        ![DSHStoreSHA256(envelope)
            isEqualToString:record[@"snapshot_sha256"]] ||
        ![record[@"manifest"][@"snapshot_sha256"]
            isEqualToString:record[@"snapshot_sha256"]]) {
      DSHSetStoreError(error, DSHProjectContextStoreErrorIntegrity);
      return nil;
    }
    NSMutableDictionary *accesses = [[self accesses:error] mutableCopy];
    if (accesses == nil) return nil;
    NSString *lastAccessed = DSHStoreISO8601(self.clock());
    accesses[snapshotId] = lastAccessed;
    if (![self writeAccesses:accesses error:error]) return nil;
    return @{
      @"envelope" : envelope,
      @"manifest" : record[@"manifest"],
      @"source_descriptor" : record[@"source_descriptor"],
      @"created_at" : record[@"created_at"],
      @"last_accessed_at" : lastAccessed,
    };
  } @finally {
    [self.lock unlock];
  }
}

- (NSDictionary *)newConsentReceiptForSnapshotId:(NSString *)snapshotId
                                    snapshotDigest:(NSString *)snapshotDigest
                                        storedData:(NSData **)storedData
                                             error:(NSError **)error {
  if (!DSHStoreCanonicalId(snapshotId) || !DSHStoreHexDigest(snapshotDigest)) {
    DSHSetStoreError(error, DSHProjectContextStoreErrorInvalidArgument);
    return nil;
  }
  NSString *receiptId = self.identifierGenerator();
  if (!DSHStoreCanonicalId(receiptId)) {
    DSHSetStoreError(error, DSHProjectContextStoreErrorInvalidArgument);
    return nil;
  }
  NSDictionary *receipt = @{
    @"schema_version" : @1,
    @"consent_receipt_id" : receiptId,
    @"snapshot_id" : snapshotId,
    @"snapshot_sha256" : snapshotDigest,
    @"confirmed_at" : DSHStoreISO8601(self.clock()),
  };
  NSMutableDictionary *storedReceipt = [receipt mutableCopy];
  storedReceipt[@"receipt_sha256"] =
      DSHStoreSHA256([NSJSONSerialization dataWithJSONObject:receipt
                                                     options:NSJSONWritingSortedKeys
                                                       error:nil]);
  NSData *data = [NSJSONSerialization dataWithJSONObject:storedReceipt
                                                  options:NSJSONWritingSortedKeys
                                                    error:nil];
  if (data == nil || data.length > DSHStoreMaxRecordBytes) {
    DSHSetStoreError(error, DSHProjectContextStoreErrorInvalidArgument);
    return nil;
  }
  if (storedData != nullptr) *storedData = data;
  return receipt;
}

- (NSDictionary *)saveConsentForSnapshotId:(NSString *)snapshotId
                             snapshotDigest:(NSString *)snapshotDigest
                                      error:(NSError **)error {
  [self.lock lock];
  @try {
    if (!DSHStoreCanonicalId(snapshotId) ||
        !DSHStoreHexDigest(snapshotDigest)) {
      DSHSetStoreError(error, DSHProjectContextStoreErrorInvalidArgument);
      return nil;
    }
    NSDictionary *snapshot = [self loadSnapshotId:snapshotId error:error];
    if (snapshot == nil ||
        ![snapshot[@"manifest"][@"snapshot_sha256"]
            isEqualToString:snapshotDigest]) {
      if (snapshot != nil) {
        DSHSetStoreError(error, DSHProjectContextStoreErrorIntegrity);
      }
      return nil;
    }
    NSData *data = nil;
    NSDictionary *receipt = [self newConsentReceiptForSnapshotId:snapshotId
                                                   snapshotDigest:snapshotDigest
                                                       storedData:&data
                                                            error:error];
    if (receipt == nil) return nil;
    NSURL *consentURL = [self consentURL:receipt[@"consent_receipt_id"]];
    if (![self publishImmutableData:data
                             toURL:consentURL
                             error:error]) {
      return nil;
    }
    if (![self pruneWithProtectedSnapshotId:snapshotId error:error]) {
      unlink(consentURL.fileSystemRepresentation);
      int directory = open(self.consentsURL.fileSystemRepresentation,
                           O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
      if (directory >= 0) {
        fsync(directory);
        close(directory);
      }
      return nil;
    }
    return receipt;
  } @finally {
    [self.lock unlock];
  }
}

- (NSDictionary *)loadConsentReceiptId:(NSString *)receiptId
                                  error:(NSError **)error {
  [self.lock lock];
  @try {
    if (!DSHStoreCanonicalId(receiptId) || ![self ensureStorage:error]) {
      if (!DSHStoreCanonicalId(receiptId)) {
        DSHSetStoreError(error, DSHProjectContextStoreErrorInvalidArgument);
      }
      return nil;
    }
    NSData *data = [self readProtectedFile:[self consentURL:receiptId]
                                 maxLength:DSHStoreMaxRecordBytes
                                     error:error];
    NSDictionary *receipt = data == nil
                                ? nil
                                : [NSJSONSerialization JSONObjectWithData:data
                                                                  options:0
                                                                    error:nil];
    if (![receipt isKindOfClass:NSDictionary.class]) {
      if (data != nil) {
        DSHSetStoreError(error, DSHProjectContextStoreErrorIntegrity);
      }
      return nil;
    }
    NSSet *keys = [NSSet setWithArray:@[
      @"schema_version", @"consent_receipt_id", @"snapshot_id",
      @"snapshot_sha256", @"confirmed_at", @"receipt_sha256"
    ]];
    NSMutableDictionary *receiptCore = [receipt mutableCopy];
    NSString *receiptDigest = [receiptCore[@"receipt_sha256"]
        isKindOfClass:NSString.class] ? receiptCore[@"receipt_sha256"] : nil;
    [receiptCore removeObjectForKey:@"receipt_sha256"];
    NSData *receiptCoreData = [NSJSONSerialization
        dataWithJSONObject:receiptCore
                   options:NSJSONWritingSortedKeys
                     error:nil];
    if (!DSHStoreDictionaryHasExactKeys(receipt, keys) ||
        ![receipt[@"schema_version"] isEqual:@1] ||
        ![receipt[@"consent_receipt_id"] isEqual:receiptId] ||
        !DSHStoreCanonicalId(receipt[@"snapshot_id"]) ||
        !DSHStoreHexDigest(receipt[@"snapshot_sha256"]) ||
        !DSHStoreHexDigest(receiptDigest) || receiptCoreData == nil ||
        ![receiptDigest isEqual:DSHStoreSHA256(receiptCoreData)] ||
        ![receipt[@"confirmed_at"] isKindOfClass:NSString.class]) {
      DSHSetStoreError(error, DSHProjectContextStoreErrorIntegrity);
      return nil;
    }
    return receiptCore;
  } @finally {
    [self.lock unlock];
  }
}

- (NSDictionary *)references:(NSError **)error {
  NSURL *url = [self referencesURL];
  if (![[NSFileManager defaultManager] fileExistsAtPath:url.path]) return @{};
  NSData *data = [self readProtectedFile:url
                              maxLength:DSHStoreMaxReferenceBytes
                                  error:error];
  NSDictionary *object = data == nil
                             ? nil
                             : [NSJSONSerialization JSONObjectWithData:data
                                                               options:0
                                                                 error:nil];
  if (![object isKindOfClass:NSDictionary.class] ||
      object.count > 10000) {
    DSHSetStoreError(error, DSHProjectContextStoreErrorIntegrity);
    return nil;
  }
  NSMutableDictionary *validated = [NSMutableDictionary dictionary];
  for (id key in object) {
    id value = object[key];
    BOOL noPriorSentinel = [key hasPrefix:@"txn:prepare:"] &&
        [value isEqual:DSHPrepareNoPriorSnapshotId];
    if (!DSHStoreSafeReferenceKey(key) ||
        (!DSHStoreCanonicalId(value) && !noPriorSentinel)) {
      DSHSetStoreError(error, DSHProjectContextStoreErrorIntegrity);
      return nil;
    }
    validated[key] = value;
  }
  return validated;
}

- (BOOL)writeReferences:(NSDictionary *)references error:(NSError **)error {
  return [self writeReferences:references applied:nil error:error];
}

- (BOOL)writeReferences:(NSDictionary *)references
                 applied:(BOOL *)applied
                   error:(NSError **)error {
  if (applied != nullptr) *applied = NO;
  if (![references isKindOfClass:NSDictionary.class]) {
    DSHSetStoreError(error, DSHProjectContextStoreErrorInvalidArgument);
    return NO;
  }
  for (id key in references) {
    id value = references[key];
    BOOL noPriorSentinel = [key isKindOfClass:NSString.class] &&
        [key hasPrefix:@"txn:prepare:"] &&
        [value isEqual:DSHPrepareNoPriorSnapshotId];
    if (!DSHStoreSafeReferenceKey(key) ||
        (!DSHStoreCanonicalId(value) && !noPriorSentinel)) {
      DSHSetStoreError(error, DSHProjectContextStoreErrorInvalidArgument);
      return NO;
    }
  }
  NSData *data = [NSJSONSerialization dataWithJSONObject:references
                                                  options:NSJSONWritingSortedKeys
                                                    error:nil];
  if (data == nil || data.length > DSHStoreMaxReferenceBytes) {
    DSHSetStoreError(error, DSHProjectContextStoreErrorInvalidArgument);
    return NO;
  }
  return [self replaceData:data atURL:[self referencesURL]
                   applied:applied error:error];
}

- (NSDictionary *)accesses:(NSError **)error {
  NSURL *url = [self accessesURL];
  if (![[NSFileManager defaultManager] fileExistsAtPath:url.path]) return @{};
  NSData *data = [self readProtectedFile:url
                              maxLength:DSHStoreMaxReferenceBytes
                                  error:error];
  NSDictionary *object = data == nil
                             ? nil
                             : [NSJSONSerialization JSONObjectWithData:data
                                                               options:0
                                                                 error:nil];
  if (![object isKindOfClass:NSDictionary.class] || object.count > 10000) {
    DSHSetStoreError(error, DSHProjectContextStoreErrorIntegrity);
    return nil;
  }
  NSMutableDictionary *validated = [NSMutableDictionary dictionary];
  for (id key in object) {
    id value = object[key];
    if (!DSHStoreCanonicalId(key) || ![value isKindOfClass:NSString.class] ||
        [value length] < 20 || [value length] > 64) {
      DSHSetStoreError(error, DSHProjectContextStoreErrorIntegrity);
      return nil;
    }
    validated[key] = value;
  }
  return validated;
}

- (BOOL)writeAccesses:(NSDictionary *)accesses error:(NSError **)error {
  NSData *data = [NSJSONSerialization dataWithJSONObject:accesses
                                                  options:NSJSONWritingSortedKeys
                                                    error:nil];
  if (data == nil || data.length > DSHStoreMaxReferenceBytes) {
    DSHSetStoreError(error, DSHProjectContextStoreErrorInvalidArgument);
    return NO;
  }
  return [self replaceData:data atURL:[self accessesURL] error:error];
}

- (BOOL)setReferenceKey:(NSString *)referenceKey
              snapshotId:(NSString *)snapshotId
                   error:(NSError **)error {
  [self.lock lock];
  @try {
    if (![referenceKey hasPrefix:@"retry:"] ||
        !DSHStoreSafeReferenceKey(referenceKey) ||
        !DSHStoreCanonicalId(snapshotId) || ![self ensureStorage:error] ||
        [self loadRecordSnapshotId:snapshotId error:error] == nil) {
      if (![referenceKey hasPrefix:@"retry:"] ||
          !DSHStoreSafeReferenceKey(referenceKey) ||
          !DSHStoreCanonicalId(snapshotId)) {
        DSHSetStoreError(error, DSHProjectContextStoreErrorInvalidArgument);
      }
      return NO;
    }
    NSDictionary *previous = [self references:error];
    if (previous == nil) return NO;
    NSString *transactionKey = DSHPrepareTransactionKey(referenceKey);
    if (transactionKey != nil && previous[transactionKey] != nil) {
      DSHSetStoreError(error, DSHProjectContextStoreErrorInvalidArgument);
      return NO;
    }
    NSMutableDictionary *references = [previous mutableCopy];
    references[referenceKey] = snapshotId;
    NSData *referenceData = [NSJSONSerialization
        dataWithJSONObject:references options:NSJSONWritingSortedKeys error:nil];
    NSNumber *oldSizeValue = nil;
    [[self referencesURL] getResourceValue:&oldSizeValue
                                    forKey:NSURLFileSizeKey error:nil];
    NSUInteger oldSize = oldSizeValue.unsignedIntegerValue;
    NSUInteger total = [self storageBytes];
    NSUInteger projected = total >= oldSize
        ? total - oldSize + referenceData.length
        : NSUIntegerMax;
    if (projected > self.capacityBytes) {
      if (![self pruneUnreferencedSnapshotsExcept:snapshotId error:error]) {
        return NO;
      }
      total = [self storageBytes];
      oldSizeValue = nil;
      [[self referencesURL] getResourceValue:&oldSizeValue
                                      forKey:NSURLFileSizeKey error:nil];
      oldSize = oldSizeValue.unsignedIntegerValue;
      projected = total >= oldSize
          ? total - oldSize + referenceData.length
          : NSUIntegerMax;
    }
    if (referenceData == nil || referenceData.length > DSHStoreMaxReferenceBytes ||
        projected > self.capacityBytes) {
      DSHSetStoreError(error, DSHProjectContextStoreErrorCapacity);
      return NO;
    }
    if (![self writeReferences:references error:error]) return NO;
    if ([self storageBytes] > self.capacityBytes) {
      [self writeReferences:previous error:nil];
      DSHSetStoreError(error, DSHProjectContextStoreErrorCapacity);
      return NO;
    }
    return YES;
  } @finally {
    [self.lock unlock];
  }
}

- (BOOL)clearReferenceKey:(NSString *)referenceKey error:(NSError **)error {
  [self.lock lock];
  @try {
    BOOL transactionReference = [referenceKey hasPrefix:@"txn:prepare:"];
    if (transactionReference || !DSHStoreSafeReferenceKey(referenceKey) ||
        ![self ensureStorage:error]) {
      if (transactionReference || !DSHStoreSafeReferenceKey(referenceKey)) {
        DSHSetStoreError(error, DSHProjectContextStoreErrorInvalidArgument);
      }
      return NO;
    }
    NSDictionary *previous = [self references:error];
    if (previous == nil) return NO;
    NSString *transactionKey = DSHPrepareTransactionKey(referenceKey);
    if (transactionKey != nil && previous[transactionKey] != nil) {
      DSHSetStoreError(error, DSHProjectContextStoreErrorInvalidArgument);
      return NO;
    }
    NSMutableDictionary *references = [previous mutableCopy];
    NSString *removedSnapshotId = references[referenceKey];
    [references removeObjectForKey:referenceKey];
    if (removedSnapshotId != nil &&
        ![references.allValues containsObject:removedSnapshotId]) {
      return [self discardSnapshotId:removedSnapshotId error:error];
    }
    return [self writeReferences:references error:error];
  } @finally {
    [self.lock unlock];
  }
}

- (BOOL)clearReferenceKeyKeepingSnapshot:(NSString *)referenceKey
                                    error:(NSError **)error {
  [self.lock lock];
  @try {
    BOOL transactionReference = [referenceKey hasPrefix:@"txn:prepare:"];
    if (transactionReference || !DSHStoreSafeReferenceKey(referenceKey) ||
        ![self ensureStorage:error]) {
      if (transactionReference || !DSHStoreSafeReferenceKey(referenceKey)) {
        DSHSetStoreError(error, DSHProjectContextStoreErrorInvalidArgument);
      }
      return NO;
    }
    NSDictionary *previous = [self references:error];
    if (previous == nil) return NO;
    NSString *transactionKey = DSHPrepareTransactionKey(referenceKey);
    if (transactionKey != nil && previous[transactionKey] != nil) {
      DSHSetStoreError(error, DSHProjectContextStoreErrorInvalidArgument);
      return NO;
    }
    NSMutableDictionary *references = [previous mutableCopy];
    [references removeObjectForKey:referenceKey];
    return [self writeReferences:references error:error];
  } @finally {
    [self.lock unlock];
  }
}

- (NSString *)snapshotIdForReferenceKey:(NSString *)referenceKey
                                   error:(NSError **)error {
  [self.lock lock];
  @try {
    if (!DSHStoreSafeReferenceKey(referenceKey) || ![self ensureStorage:error]) {
      if (!DSHStoreSafeReferenceKey(referenceKey)) {
        DSHSetStoreError(error, DSHProjectContextStoreErrorInvalidArgument);
      }
      return nil;
    }
    NSDictionary *references = [self references:error];
    return references[referenceKey];
  } @finally {
    [self.lock unlock];
  }
}

- (BOOL)isSnapshotIdAuthorized:(NSString *)snapshotId
             activeReferenceKey:(NSString *)activeReferenceKey
                          error:(NSError **)error {
  [self.lock lock];
  @try {
    if (!DSHStoreCanonicalId(snapshotId) ||
        (activeReferenceKey != nil &&
         !DSHStoreSafeReferenceKey(activeReferenceKey)) ||
        ![self ensureStorage:error]) {
      if (!DSHStoreCanonicalId(snapshotId) ||
          (activeReferenceKey != nil &&
           !DSHStoreSafeReferenceKey(activeReferenceKey))) {
        DSHSetStoreError(error, DSHProjectContextStoreErrorInvalidArgument);
      }
      return NO;
    }
    NSDictionary *references = [self references:error];
    if (references == nil) return NO;
    if (activeReferenceKey != nil &&
        [references[activeReferenceKey] isEqual:snapshotId]) return YES;
    for (NSString *key in references) {
      BOOL permittedPrefix = [key hasPrefix:@"retry:"] ||
                             (activeReferenceKey == nil &&
                              [key hasPrefix:@"active:"]);
      if (permittedPrefix &&
          [references[key] isEqual:snapshotId]) {
        return YES;
      }
    }
    return NO;
  } @finally {
    [self.lock unlock];
  }
}

- (DSHProjectContextAuthorizationLease *)
    beginAuthorizationForSnapshotId:(NSString *)snapshotId
                  activeReferenceKey:(NSString *)activeReferenceKey
                               error:(NSError **)error {
  [self.lock lock];
  @try {
    if (![self isSnapshotIdAuthorized:snapshotId
                    activeReferenceKey:activeReferenceKey error:error]) {
      if (error != nil && *error == nil) {
        DSHSetStoreError(error, DSHProjectContextStoreErrorNotFound);
      }
      return nil;
    }
    NSDictionary *snapshot = [self loadSnapshotId:snapshotId error:error];
    if (snapshot == nil) return nil;
    DSHProjectContextAuthorizationLease *lease =
        [[DSHProjectContextAuthorizationLease alloc] init];
    lease.store = self;
    lease.snapshotId = snapshotId;
    lease.snapshot = snapshot;
    return lease;
  } @finally {
    [self.lock unlock];
  }
}

- (id)completeAuthorizationLease:
          (DSHProjectContextAuthorizationLease *)authorizationLease
               activeReferenceKey:(NSString *)activeReferenceKey
                        operation:
                            (DSHProjectContextAuthorizedOperation)operation
                            error:(NSError **)error {
  [self.lock lock];
  @try {
    if (authorizationLease == nil || authorizationLease.finished ||
        authorizationLease.store != self || operation == nil ||
        ![self isSnapshotIdAuthorized:authorizationLease.snapshotId
                    activeReferenceKey:activeReferenceKey error:error]) {
      if (authorizationLease.store == self) authorizationLease.finished = YES;
      if (error != nil && *error == nil) {
        DSHSetStoreError(error, DSHProjectContextStoreErrorNotFound);
      }
      return nil;
    }
    NSDictionary *current = [self loadSnapshotId:authorizationLease.snapshotId
                                            error:error];
    NSDictionary *original = authorizationLease.snapshot;
    if (current == nil ||
        ![current[@"manifest"][@"snapshot_sha256"]
            isEqual:original[@"manifest"][@"snapshot_sha256"]] ||
        ![current[@"manifest"][@"source_fingerprint"]
            isEqual:original[@"manifest"][@"source_fingerprint"]]) {
      authorizationLease.finished = YES;
      if (current != nil) {
        DSHSetStoreError(error, DSHProjectContextStoreErrorIntegrity);
      }
      return nil;
    }
    authorizationLease.finished = YES;
    return operation(current, error);
  } @finally {
    [self.lock unlock];
  }
}

- (void)cancelAuthorizationLease:
    (DSHProjectContextAuthorizationLease *)authorizationLease {
  [self.lock lock];
  if (authorizationLease.store == self) authorizationLease.finished = YES;
  [self.lock unlock];
}

- (NSArray<NSURL *> *)fileURLsForSnapshotId:(NSString *)snapshotId
                                      error:(NSError **)error {
  [self.lock lock];
  @try {
    if (!DSHStoreCanonicalId(snapshotId) ||
        [self loadRecordSnapshotId:snapshotId error:error] == nil) {
      if (!DSHStoreCanonicalId(snapshotId)) {
        DSHSetStoreError(error, DSHProjectContextStoreErrorInvalidArgument);
      }
      return @[];
    }
    NSMutableArray<NSURL *> *files = [NSMutableArray arrayWithObjects:
        [self envelopeURL:snapshotId], [self recordURL:snapshotId], nil];
    NSArray<NSURL *> *consents = [[NSFileManager defaultManager]
        contentsOfDirectoryAtURL:self.consentsURL
      includingPropertiesForKeys:nil
                         options:NSDirectoryEnumerationSkipsHiddenFiles
                           error:nil];
    for (NSURL *url in consents) {
      NSData *data = [self readProtectedFile:url
                                  maxLength:DSHStoreMaxRecordBytes
                                      error:nil];
      NSDictionary *receipt = data == nil
                                  ? nil
                                  : [NSJSONSerialization JSONObjectWithData:data
                                                                    options:0
                                                                      error:nil];
      if ([receipt isKindOfClass:NSDictionary.class] &&
          [receipt[@"snapshot_id"] isEqual:snapshotId]) {
        [files addObject:url];
      }
    }
    return files;
  } @finally {
    [self.lock unlock];
  }
}

- (BOOL)discardSnapshotId:(NSString *)snapshotId error:(NSError **)error {
  [self.lock lock];
  @try {
    if (!DSHStoreCanonicalId(snapshotId) || ![self ensureStorage:error]) {
      if (!DSHStoreCanonicalId(snapshotId)) {
        DSHSetStoreError(error, DSHProjectContextStoreErrorInvalidArgument);
      }
      return NO;
    }
    NSDictionary *storedReferences = [self references:error];
    for (NSString *key in storedReferences.allKeys) {
      if (![key hasPrefix:@"txn:prepare:"]) continue;
      NSString *conversation = [key substringFromIndex:@"txn:prepare:".length];
      NSString *activeKey = [@"active:" stringByAppendingString:conversation];
      NSString *rollbackSnapshot = storedReferences[key];
      NSString *preparedSnapshot = storedReferences[activeKey];
      if ([rollbackSnapshot isEqual:snapshotId]) {
        DSHSetStoreError(error, DSHProjectContextStoreErrorInvalidArgument);
        return NO;
      }
      if ([preparedSnapshot isEqual:snapshotId]) {
        if (![self abortPrepareTransactionForSnapshotId:snapshotId
                                      activeReferenceKey:activeKey
                                                   error:error]) {
          return NO;
        }
        storedReferences = [self references:error];
        if (storedReferences == nil) return NO;
        break;
      }
    }
    NSDictionary *storedAccesses = [self accesses:error];
    if (storedReferences == nil || storedAccesses == nil) return NO;
    NSError *enumerationError = nil;
    NSArray<NSURL *> *consents = [[NSFileManager defaultManager]
        contentsOfDirectoryAtURL:self.consentsURL
      includingPropertiesForKeys:nil options:0 error:&enumerationError];
    if (consents == nil) {
      DSHSetStoreError(error, DSHProjectContextStoreErrorUnavailable);
      return NO;
    }
    NSMutableArray<NSURL *> *matchingConsents = [NSMutableArray array];
    for (NSURL *url in consents) {
      NSError *readError = nil;
      NSData *data = [self readProtectedFile:url
                                  maxLength:DSHStoreMaxRecordBytes error:&readError];
      if (data == nil && readError.code == DSHProjectContextStoreErrorUnavailable) {
        DSHSetStoreError(error, DSHProjectContextStoreErrorUnavailable);
        return NO;
      }
      NSDictionary *receipt = data == nil ? nil
          : [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
      if ([receipt isKindOfClass:NSDictionary.class] &&
          [receipt[@"snapshot_id"] isEqual:snapshotId]) {
        [matchingConsents addObject:url];
      }
    }
    NSMutableDictionary *references = [storedReferences mutableCopy];
    NSArray *keys = [references allKeysForObject:snapshotId];
    [references removeObjectsForKeys:keys];
    NSMutableDictionary *accesses = [storedAccesses mutableCopy];
    [accesses removeObjectForKey:snapshotId];
    if (![self writeReferences:references error:error]) return NO;
    if (![self writeAccesses:accesses error:error]) {
      [self writeReferences:storedReferences error:nil];
      return NO;
    }
    BOOL success = DSHUnlinkURLIfPresent([self envelopeURL:snapshotId]);
    success = DSHUnlinkURLIfPresent([self recordURL:snapshotId]) && success;
    for (NSURL *url in matchingConsents) {
      success = DSHUnlinkURLIfPresent(url) && success;
    }
    for (NSURL *directoryURL in @[self.snapshotsURL, self.consentsURL,
                                  self.rootURL]) {
      int descriptor = open(directoryURL.fileSystemRepresentation,
                            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
      if (descriptor < 0 || fsync(descriptor) != 0) success = NO;
      if (descriptor >= 0) close(descriptor);
    }
    if (!success) {
      DSHSetStoreError(error, DSHProjectContextStoreErrorUnavailable);
    }
    return success;
  } @finally {
    [self.lock unlock];
  }
}

- (NSUInteger)storageBytes {
  NSUInteger total = 0;
  for (NSURL *directory in @[ self.snapshotsURL, self.consentsURL ]) {
    NSArray<NSURL *> *files = [[NSFileManager defaultManager]
        contentsOfDirectoryAtURL:directory
      includingPropertiesForKeys:@[NSURLFileSizeKey]
                         options:NSDirectoryEnumerationSkipsHiddenFiles
                           error:nil];
    for (NSURL *file in files) {
      NSNumber *size = nil;
      if ([file getResourceValue:&size forKey:NSURLFileSizeKey error:nil]) {
        total += size.unsignedIntegerValue;
      }
    }
  }
  NSNumber *referenceSize = nil;
  if ([[self referencesURL] getResourceValue:&referenceSize
                                       forKey:NSURLFileSizeKey
                                        error:nil]) {
    total += referenceSize.unsignedIntegerValue;
  }
  NSNumber *accessSize = nil;
  if ([[self accessesURL] getResourceValue:&accessSize
                                    forKey:NSURLFileSizeKey
                                     error:nil]) {
    total += accessSize.unsignedIntegerValue;
  }
  return total;
}

- (NSUInteger)snapshotArtifactBytes:(NSString *)snapshotId {
  NSUInteger total = 0;
  for (NSURL *url in [self fileURLsForSnapshotId:snapshotId error:nil]) {
    NSNumber *size = nil;
    if ([url getResourceValue:&size forKey:NSURLFileSizeKey error:nil]) {
      total += size.unsignedIntegerValue;
    }
  }
  return total;
}

- (BOOL)pruneUnreferencedSnapshotsExcept:(NSString *)protectedSnapshotId
                                    error:(NSError **)error {
  NSDictionary *references = [self references:error];
  if (references == nil) return NO;
  NSSet *referenced = [NSSet setWithArray:references.allValues];
  NSArray<NSURL *> *files = [[NSFileManager defaultManager]
      contentsOfDirectoryAtURL:self.snapshotsURL
    includingPropertiesForKeys:nil options:0 error:nil];
  NSMutableSet<NSString *> *snapshotIds = [NSMutableSet set];
  for (NSURL *url in files) {
    if (![url.pathExtension isEqual:@"json"]) continue;
    NSString *snapshotId = url.lastPathComponent.stringByDeletingPathExtension;
    if (DSHStoreCanonicalId(snapshotId)) [snapshotIds addObject:snapshotId];
  }
  for (NSString *snapshotId in snapshotIds) {
    if ([snapshotId isEqual:protectedSnapshotId] ||
        [referenced containsObject:snapshotId]) {
      continue;
    }
    if (![self discardSnapshotId:snapshotId error:error]) return NO;
  }
  return YES;
}

- (BOOL)pruneWithProtectedSnapshotId:(NSString *)protectedSnapshotId
                                error:(NSError **)error {
  [self.lock lock];
  @try {
    if (![self ensureStorage:error]) return NO;
    NSDictionary *references = [self references:error];
    if (references == nil) return NO;
    NSDictionary *accesses = [self accesses:error];
    if (accesses == nil) return NO;
    NSSet *referenced = [NSSet setWithArray:references.allValues];
    while ([self storageBytes] > self.capacityBytes) {
      NSArray<NSURL *> *records = [[NSFileManager defaultManager]
          contentsOfDirectoryAtURL:self.snapshotsURL
        includingPropertiesForKeys:nil
                           options:NSDirectoryEnumerationSkipsHiddenFiles
                             error:nil];
      NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
      for (NSURL *url in records) {
        if (![url.pathExtension isEqualToString:@"json"]) continue;
        NSString *snapshotId = url.lastPathComponent.stringByDeletingPathExtension;
        if ([snapshotId isEqual:protectedSnapshotId] ||
            [referenced containsObject:snapshotId]) {
          continue;
        }
        NSDictionary *record = [self loadRecordSnapshotId:snapshotId error:nil];
        if (record != nil) {
          [candidates addObject:@{
            @"snapshot_id" : snapshotId,
            @"last_accessed_at" : accesses[snapshotId]
                ?: record[@"last_accessed_at"],
          }];
        }
      }
      [candidates sortUsingComparator:^NSComparisonResult(NSDictionary *left,
                                                          NSDictionary *right) {
        NSComparisonResult date =
            [left[@"last_accessed_at"] compare:right[@"last_accessed_at"]];
        return date == NSOrderedSame
                   ? [left[@"snapshot_id"] compare:right[@"snapshot_id"]]
                   : date;
      }];
      NSDictionary *victim = candidates.firstObject;
      if (victim == nil) {
        DSHSetStoreError(error, DSHProjectContextStoreErrorCapacity);
        return NO;
      }
      if (![self discardSnapshotId:victim[@"snapshot_id"] error:error]) {
        return NO;
      }
    }
    return YES;
  } @finally {
    [self.lock unlock];
  }
}

@end
