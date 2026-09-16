#import "AgentWorkspaceReadTools.h"
#import "AgentNativeWAL.h"
#import <CommonCrypto/CommonDigest.h>
#include "rish_agent_core.h"
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

// Plain content SHA-256 for model-visible source snapshot binding. This is
// distinct from domain-separated WAL identity hashes.
NSString *DSHAgentWorkspacePlainSHA256(NSData *data) {
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *value = [NSMutableString stringWithCapacity:64];
  for (NSUInteger i = 0; i < sizeof(digest); i++) [value appendFormat:@"%02x", digest[i]];
  return value;
}

// The workspace executor's judgements live in the shared core
// (modules/rish/core, `rish_agent_workspace_tool_reduce`): which paths it may
// touch, what a revision is, what a listing looks like, and what a person is
// shown before they approve a write.  What stays here is the capability — a
// directory descriptor, bytes read and written, `fstatat` — and the caps the
// host enforces while doing it, which it reads back from the core rather than
// keeping a second copy of.
NSDictionary *DSHAgentWorkspaceReduce(NSString *op,
                                             NSDictionary *fields,
                                             NSError **error) {
  NSMutableDictionary *envelope = [fields mutableCopy];
  envelope[@"op"] = op;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:envelope options:0
                                                    error:nil];
  char *raw = bytes == nil ? NULL : rish_agent_workspace_tool_reduce(
      (const char *)bytes.bytes, bytes.length);
  if (raw == NULL) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0
                                                error:nil];
  if (![reply isKindOfClass:NSDictionary.class]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  if ([reply[@"ok"] isEqual:@YES]) {
    if (error != nullptr) *error = nil;
    return reply;
  }
  NSInteger code = [reply[@"error"] isKindOfClass:NSNumber.class]
      ? [reply[@"error"] integerValue] : 0;
  if (code < DSHAgentNativeStoreErrorInvalidArgument ||
      code > DSHAgentNativeStoreErrorPersistence) {
    code = DSHAgentNativeStoreErrorCorrupt;
  }
  DSHSetAgentNativeStoreError(error, (DSHAgentNativeStoreErrorCode)code);
  return nil;
}

NSUInteger DSHAgentWorkspaceBound(NSString *name, NSUInteger fallback) {
  static NSDictionary *bounds = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    bounds = DSHAgentWorkspaceReduce(@"bounds", @{}, nullptr);
  });
  id value = bounds[name];
  return [value isKindOfClass:NSNumber.class] ? [value unsignedIntegerValue]
                                              : fallback;
}

NSArray<NSString *> *DSHAgentWorkspacePathComponents(id value,
                                                             BOOL allowRoot) {
  if (![value isKindOfClass:NSString.class]) return nil;
  NSDictionary *reply = DSHAgentWorkspaceReduce(@"path_components", @{
    @"path" : value, @"allow_root" : @(allowRoot),
  }, nullptr);
  id components = reply[@"components"];
  return [components isKindOfClass:NSArray.class] ? components : nil;
}

int DSHAgentWorkspaceOpenDirectory(int rootDescriptor,
                                           NSArray<NSString *> *components) {
  int current = dup(rootDescriptor);
  if (current < 0) return -1;
  for (NSString *component in components) {
    int next = openat(current, component.fileSystemRepresentation,
                      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    close(current);
    if (next < 0) return -1;
    current = next;
  }
  return current;
}

int DSHAgentWorkspaceOpenParent(int rootDescriptor,
                                       NSArray<NSString *> *components,
                                       NSString **name) {
  if (components.count == 0) return -1;
  int parent = DSHAgentWorkspaceOpenDirectory(
      rootDescriptor,
      [components subarrayWithRange:NSMakeRange(0, components.count - 1)]);
  if (parent >= 0 && name != nullptr) *name = components.lastObject;
  return parent;
}

NSString *DSHAgentWorkspaceRevision(struct stat metadata) {
  // The host reads the numbers; their spelling is the rule, so the core says
  // it.  Revisions are opaque bounded metadata, not a new protocol digest.
  NSDictionary *reply = DSHAgentWorkspaceReduce(@"revision", @{
    @"dev" : @((unsigned long long)metadata.st_dev),
    @"ino" : @((unsigned long long)metadata.st_ino),
    @"size" : @((unsigned long long)metadata.st_size),
    @"mtime_sec" : @((unsigned long long)metadata.st_mtimespec.tv_sec),
    @"mtime_nsec" : @((unsigned long long)metadata.st_mtimespec.tv_nsec),
  }, nullptr);
  id revision = reply[@"revision"];
  return [revision isKindOfClass:NSString.class] ? revision : @"";
}

NSString *DSHAgentWorkspaceFeedback(NSDictionary *feedback,
                                            NSError **error) {
  // Canonical bytes, the protected cap, and the contract the ledger will
  // apply — one decision, made once.
  id reported = DSHAgentWorkspaceReduce(@"feedback", @{
    @"feedback" : feedback ?: NSNull.null,
  }, error)[@"feedback"];
  return [reported isKindOfClass:NSString.class] ? reported : nil;
}

@implementation DSHAgentWorkspaceToolExecutor (DirectoryObservations)
- (struct dirent *)nextEntryInDirectory:(DIR *)directory {
  return readdir(directory);
}

- (int)statEntryNamed:(const char *)name
           directory:(int)descriptor
            metadata:(struct stat *)metadata {
  return fstatat(descriptor, name, metadata, AT_SYMLINK_NOFOLLOW);
}

// The caller retains entryError outside its per-entry autorelease pool.
- (BOOL)appendDirectoryEntry:(struct dirent *)entry
                 descriptor:(int)directoryDescriptor
                   observed:(NSMutableArray<NSDictionary *> *)observed
                      error:(NSError **)error {
  NSData *nameBytes = [NSData dataWithBytes:entry->d_name
                                     length:strlen(entry->d_name)];
  NSString *name = [[NSString alloc] initWithData:nameBytes
                                         encoding:NSUTF8StringEncoding];
  NSMutableDictionary *observation = [@{
    @"name": name ?: @"", @"kind": name == nil ? @"unnamed" : @"uninspected",
  } mutableCopy];
  NSDictionary *decision = DSHAgentWorkspaceReduce(@"directory_entry_decision", @{
    @"visible_count": @(observed.count), @"entry": observation,
  }, error);
  if (decision == nil) return NO;
  if ([decision[@"decision"] isEqual:@"skip"]) return YES;
  if (![decision[@"decision"] isEqual:@"inspect"]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return NO;
  }
  struct stat metadata = {};
  BOOL usable = [self statEntryNamed:entry->d_name directory:directoryDescriptor
                           metadata:&metadata] == 0 &&
      !S_ISLNK(metadata.st_mode) &&
      (S_ISREG(metadata.st_mode) || S_ISDIR(metadata.st_mode)) &&
      (!S_ISREG(metadata.st_mode) || metadata.st_nlink == 1);
  observation[@"kind"] = !usable ? @"invalid"
      : (S_ISDIR(metadata.st_mode) ? @"directory" : @"file");
  observation[@"revision"] = usable ? DSHAgentWorkspaceRevision(metadata) : @"";
  decision = DSHAgentWorkspaceReduce(@"directory_entry_decision", @{
    @"visible_count": @(observed.count), @"entry": observation,
  }, error);
  if (decision == nil) return NO;
  if (![decision[@"decision"] isEqual:@"include"]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return NO;
  }
  [observed addObject:observation];
  return YES;
}

// Ask the core about each name before stat, and each observation before
// advancing. Only included entries are retained, so allocation and metadata
// work stop at the same bound as the original descriptor walk.
- (BOOL)entryListForDirectoryDescriptor:(int)directoryDescriptor
                               entries:(NSArray **)entriesOut
                           fingerprint:(NSString **)fingerprintOut
                                 error:(NSError **)error {
  int duplicate = dup(directoryDescriptor);
  DIR *directory = duplicate < 0 ? nullptr : fdopendir(duplicate);
  if (directory == nullptr) {
    if (duplicate >= 0) close(duplicate);
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorUnavailable);
    return NO;
  }
  NSMutableArray<NSDictionary *> *observed = [NSMutableArray array];
  int readError = 0;
  while (true) {
    // Other calls in the loop may set errno even on success. Only the errno
    // produced by this readdir call can describe the end of this walk.
    errno = 0;
    struct dirent *entry = [self nextEntryInDirectory:directory];
    if (entry == nullptr) {
      readError = errno;
      break;
    }
    NSError *entryError = nil;
    BOOL accepted = NO;
    @autoreleasepool {
      accepted = [self appendDirectoryEntry:entry descriptor:directoryDescriptor
          observed:observed error:&entryError];
    }
    if (!accepted) {
      closedir(directory);
      if (error != nullptr) *error = entryError;
      return NO;
    }
  }
  closedir(directory);
  if (readError != 0) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorUnavailable);
    return NO;
  }
  NSDictionary *listing = DSHAgentWorkspaceReduce(@"directory_listing", @{
    @"entries": observed,
  }, error);
  if (listing == nil) return NO;
  if (entriesOut != nullptr) *entriesOut = listing[@"entries"];
  if (fingerprintOut != nullptr) {
    *fingerprintOut = listing[@"directory_fingerprint_sha256"];
  }
  return YES;
}
@end
