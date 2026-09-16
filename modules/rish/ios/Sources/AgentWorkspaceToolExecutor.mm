#import "AgentWorkspaceToolExecutor.h"
#import "AgentWorkspaceParent.h"
#import "AgentWorkspaceReadTools.h"

#import "AgentNativeWAL.h"
#import "AgentRootResolver.h"
#import "LocalWorkspaceAccess.h"

#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/stdio.h>
#include <unistd.h>

// Leaves canonical-envelope headroom under the protected feedback cap.
#define DSHAgentWorkspaceMaxReadBytes \
    DSHAgentWorkspaceBound(@"max_read_bytes", 60 * 1024)

// How much of an existing file is read to build the preview.  The reading is
// the host's; the bound is the core's, along with every bound inside the diff
// itself.  The preview is computed from the prepared intent (validated
// arguments + current file state), never from unvalidated model text.
#define DSHAgentApprovalMaxPriorReadBytes \
    DSHAgentWorkspaceBound(@"max_prior_read_bytes", 64 * 1024)

/// The preview a person reads before they approve a write.  The whole of it —
/// the anchored line diff, every bound, and the honest truncation flag — is a
/// rule, so there is one copy of it and it is not this one.  `truncatedOut` is
/// carried in as well as out: a prior read the host already cut short stays
/// marked.
static NSString *DSHAgentApprovalUnifiedDiff(NSString *prior,
                                              NSString *next,
                                              BOOL *truncatedOut) {
  NSDictionary *reply = DSHAgentWorkspaceReduce(@"diff_preview", @{
    @"prior" : prior ?: NSNull.null,
    @"next" : next ?: NSNull.null,
    @"prior_truncated" : @(truncatedOut != nullptr && *truncatedOut),
  }, nullptr);
  if (reply == nil) return nil;
  if (truncatedOut != nullptr) {
    *truncatedOut = [reply[@"diff_truncated"] isEqual:@YES];
  }
  id diff = reply[@"diff_preview"];
  return [diff isKindOfClass:NSString.class] ? diff : nil;
}

static BOOL DSHAgentWorkspaceSameFileState(struct stat left,
                                           struct stat right) {
  return left.st_dev == right.st_dev && left.st_ino == right.st_ino &&
      left.st_mode == right.st_mode && left.st_size == right.st_size &&
      left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec &&
      left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec;
}

static BOOL DSHAgentWorkspaceStatMatches(int parent,
                                         NSString *name,
                                         struct stat expected,
                                         struct stat *actualOut) {
  struct stat actual = {};
  if (fstatat(parent, name.fileSystemRepresentation, &actual,
              AT_SYMLINK_NOFOLLOW) != 0 ||
      !DSHAgentWorkspaceSameFileState(actual, expected) ||
      (S_ISREG(actual.st_mode) && actual.st_nlink != 1)) return NO;
  if (actualOut != nullptr) *actualOut = actual;
  return YES;
}

static BOOL DSHAgentWorkspaceWriteAll(int descriptor, NSData *data) {
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

static NSDictionary *DSHAgentWorkspaceFailure(NSString *name,
                                               NSString *failureCode,
                                               BOOL ambiguous,
                                               NSError **error) {
  // `ambiguous` says the effect may already have happened, which is the one
  // thing a retry has to know; the core builds the feedback and checks it
  // against the same contract the ledger will apply.
  return DSHAgentWorkspaceReduce(@"failure_result", @{
    @"name" : name ?: NSNull.null,
    @"failure_code" : failureCode ?: NSNull.null,
    @"ambiguous" : @(ambiguous),
  }, error)[@"result"];
}

static NSDictionary *DSHAgentWorkspaceWriteFailure(NSString *name, NSString *code,
    BOOL ambiguous, DSHAgentWorkspaceParentCreation *parents, NSError **error) {
  BOOL cleaned = parents == nil || [parents removeCreatedDirectoriesWithError:nil];
  return DSHAgentWorkspaceFailure(name, code, ambiguous || !cleaned, error);
}

@interface DSHAgentWorkspaceToolExecutor ()
@property(nonatomic, strong, readwrite) DSHAgentRootResolver *rootResolver;
@end

@implementation DSHAgentWorkspaceToolExecutor

- (instancetype)initWithRootResolver:(DSHAgentRootResolver *)rootResolver {
  self = [super init];
  if (self) _rootResolver = rootResolver;
  return self;
}

- (DSHAgentWorkspaceParentCreation *)parentCreationForRoot:(int)rootDescriptor
                                               components:(NSArray<NSString *> *)components
                                                     plan:(NSDictionary *)plan {
  return [[DSHAgentWorkspaceParentCreation alloc] initWithRootDescriptor:rootDescriptor
      components:components plan:plan];
}

- (NSDictionary *)prepareToolNamed:(NSString *)name
                          arguments:(NSDictionary *)arguments
                               root:(NSDictionary *)root
                              error:(NSError **)error {
  if (![DSHAgentRootResolver validateAgentRootProjection:root error:error] ||
      ![arguments isKindOfClass:NSDictionary.class] ||
      (![name isEqualToString:@"list_dir"] &&
       ![name isEqualToString:@"read_file"] &&
       ![name isEqualToString:@"write_file"])) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  BOOL write = [name isEqualToString:@"write_file"];
  NSString *agentCapability = write ? @"file_write" : @"file_read";
  if (![root[@"capabilities"] containsObject:agentCapability]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
    return nil;
  }
  NSString *path = [name isEqualToString:@"list_dir"] && arguments.count == 0
      ? @"" : arguments[@"path"];
  NSArray *components = DSHAgentWorkspacePathComponents(
      path, [name isEqualToString:@"list_dir"]);
  if (components == nil ||
      (([name isEqualToString:@"read_file"] || write) &&
       ![arguments[@"path"] isKindOfClass:NSString.class])) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  if (([name isEqualToString:@"read_file"] &&
       !DSHAgentExactDictionaryKeys(arguments, @[@"path"])) ||
      ([name isEqualToString:@"list_dir"] && arguments.count != 0 &&
       !DSHAgentExactDictionaryKeys(arguments, @[@"path"]))) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  __block NSDictionary *precondition = nil;
  __block NSDictionary *approvalPreview = nil;
  BOOL succeeded = [self.rootResolver performOperationForFrozenRoot:root
      mode:write ? DSHAgentRootOperationModeWrite
                 : DSHAgentRootOperationModeRead
      timeout:5.0
      block:^BOOL(int rootDescriptor, __unused git_repository *repository,
                  NSError **blockError) {
    (void)blockError;
    if ([name isEqualToString:@"list_dir"]) {
      int directory = DSHAgentWorkspaceOpenDirectory(rootDescriptor, components);
      NSString *fingerprint = nil;
      BOOL ok = directory >= 0 && [self entryListForDirectoryDescriptor:directory
          entries:nullptr fingerprint:&fingerprint error:blockError];
      if (directory >= 0) close(directory);
      if (!ok) return NO;
      precondition = @{
        @"schema_version" : @1,
        @"kind" : @"list_dir",
        @"directory_fingerprint_sha256" : fingerprint,
      };
      // The ledger and the Store both require every preview path to be a
      // non-empty relative path, so the workspace root is previewed as no
      // path at all rather than as "".
      approvalPreview = @{
        @"schema_version" : @1, @"kind" : @"list_dir",
        @"paths" : components.count == 0 ? @[] : @[path],
        @"content_bytes" : NSNull.null,
        @"prior" : NSNull.null, @"diff_preview" : NSNull.null,
        @"diff_truncated" : @NO,
      };
      return YES;
    }
    NSString *leaf = components.lastObject;
    NSDictionary *parentPlan = nil;
    int parent = write
        ? DSHAgentWorkspaceProbeParent(rootDescriptor, components, &parentPlan, blockError)
        : DSHAgentWorkspaceOpenParent(rootDescriptor, components, &leaf);
    if (parent < 0 && parentPlan == nil) {
      if (blockError != nullptr && *blockError == nil)
        DSHSetAgentNativeStoreError(blockError, DSHAgentNativeStoreErrorInvalidArgument);
      return NO;
    }
    struct stat metadata = {};
    int statResult = parent < 0 ? -1 : fstatat(parent, leaf.fileSystemRepresentation,
                                              &metadata, AT_SYMLINK_NOFOLLOW);
    int lookupError = parent < 0 ? ENOENT : errno;
    if ([name isEqualToString:@"read_file"]) {
      if (statResult != 0 || !S_ISREG(metadata.st_mode) ||
          S_ISLNK(metadata.st_mode) || metadata.st_nlink != 1) {
        if (parent >= 0) close(parent);
        DSHSetAgentNativeStoreError(blockError, DSHAgentNativeStoreErrorNotFound);
        return NO;
      }
      precondition = @{
        @"schema_version" : @1,
        @"kind" : @"read_file",
        @"source_revision" : DSHAgentWorkspaceRevision(metadata),
      };
      approvalPreview = @{
        @"schema_version" : @1, @"kind" : @"read_file",
        @"paths" : @[path], @"content_bytes" : NSNull.null,
        @"prior" : NSNull.null, @"diff_preview" : NSNull.null,
        @"diff_truncated" : @NO,
      };
      if (parent >= 0) close(parent);
      return YES;
    }
    // The three shapes a write may take, and the prior each one asserts. A
    // call that names neither form asserts the file is absent.
    NSDictionary *expectedPriorReply = DSHAgentWorkspaceReduce(
        @"write_expected_prior", @{ @"arguments" : arguments }, nullptr);
    NSData *content = [arguments[@"content"] isKindOfClass:NSString.class]
        ? [arguments[@"content"] dataUsingEncoding:NSUTF8StringEncoding] : nil;
    if (expectedPriorReply == nil || content == nil ||
        content.length > DSHAgentNativeWALMaxSingleWriteBytes ||
        (statResult == 0 && (!S_ISREG(metadata.st_mode) ||
                            S_ISLNK(metadata.st_mode) || metadata.st_nlink != 1)) ||
        (statResult != 0 && lookupError != ENOENT)) {
      if (parent >= 0) close(parent);
      DSHSetAgentNativeStoreError(blockError, DSHAgentNativeStoreErrorInvalidArgument);
      return NO;
    }
    NSDictionary *actualPrior = statResult == 0
        ? @{ @"schema_version" : @1, @"kind" : @"known",
             @"revision" : DSHAgentWorkspaceRevision(metadata) }
        : @{ @"schema_version" : @1, @"kind" : @"absent" };
    NSDictionary *expectedPrior = expectedPriorReply[@"expected_prior"];
    if (![expectedPrior isEqual:actualPrior]) {
      if (parent >= 0) close(parent);
      DSHSetAgentNativeStoreError(blockError, DSHAgentNativeStoreErrorConflict);
      return NO;
    }
    NSData *pathBytes = [path dataUsingEncoding:NSUTF8StringEncoding];
    NSString *pathDigest = DSHAgentHB(@"relative-path", pathBytes, blockError);
    NSString *contentDigest = DSHAgentHB(@"file-content", content, blockError);
    if (pathDigest == nil || contentDigest == nil) {
      if (parent >= 0) close(parent);
      return NO;
    }
    // Bounded prior-content read for the diff preview.  The precondition
    // remains authoritative for the write; the preview is display-only.
    NSData *priorContent = nil;
    BOOL priorTruncated = NO;
    if (statResult == 0) {
      int file = openat(parent, leaf.fileSystemRepresentation,
                        O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
      if (file >= 0) {
        NSMutableData *data = [NSMutableData dataWithCapacity:
            MIN((NSUInteger)metadata.st_size,
                DSHAgentApprovalMaxPriorReadBytes)];
        uint8_t buffer[8192];
        ssize_t got;
        while ((got = read(file, buffer, sizeof(buffer))) > 0) {
          if (data.length + (NSUInteger)got > DSHAgentApprovalMaxPriorReadBytes) {
            priorTruncated = YES;
            break;
          }
          [data appendBytes:buffer length:(NSUInteger)got];
        }
        close(file);
        priorContent = data;
      }
    }
    NSMutableDictionary *writeCondition = [@{
      @"schema_version" : parentPlan == nil ? @2 : @3,
      @"kind" : @"write_file",
      @"relative_path_sha256" : pathDigest,
      @"prior" : actualPrior,
      @"content_sha256" : contentDigest,
      @"content_bytes" : @(content.length),
    } mutableCopy];
    if (parentPlan != nil) writeCondition[@"parent_plan"] = parentPlan;
    precondition = [writeCondition copy];
    if (parent >= 0) close(parent);
    NSString *priorText = priorContent == nil ? nil
        : [[NSString alloc] initWithData:priorContent
                                encoding:NSUTF8StringEncoding];
    BOOL diffTruncated = priorTruncated;
    NSString *diffPreview = priorContent == nil ? nil
        : DSHAgentApprovalUnifiedDiff(priorText, arguments[@"content"],
                                      &diffTruncated);
    approvalPreview = @{
      @"schema_version" : @1,
      @"kind" : @"write_file",
      @"paths" : @[path],
      @"content_bytes" : @(content.length),
      // The preview prior always carries `bytes` (null when nothing was
      // read); the ledger and the Store validate that exact shape and reject
      // a new-file write whose prior omits the key.
      @"prior" : statResult == 0
          ? @{ @"schema_version" : @1, @"kind" : @"known",
               @"bytes" : priorContent == nil ? NSNull.null
                   : @(priorContent.length) }
          : @{ @"schema_version" : @1, @"kind" : @"absent",
               @"bytes" : NSNull.null },
      @"diff_preview" : diffPreview ?: NSNull.null,
      @"diff_truncated" : @(diffTruncated),
    };
    return YES;
  } error:error];
  if (!succeeded || precondition == nil) return nil;
  return @{
    @"schema_version" : @1,
    @"precondition" : precondition,
    @"reserved_write_bytes" : write
        ? precondition[@"content_bytes"] : @0,
    @"approval_preview" : approvalPreview ?: NSNull.null,
  };
}

- (NSDictionary *)executeToolNamed:(NSString *)name
                          arguments:(NSDictionary *)arguments
                               root:(NSDictionary *)root
                       precondition:(NSDictionary *)precondition
                              error:(NSError **)error {
  if (![DSHAgentRootResolver validateAgentRootProjection:root error:error] ||
      ![arguments isKindOfClass:NSDictionary.class] ||
      ![precondition isKindOfClass:NSDictionary.class] ||
      ![precondition[@"kind"] isEqual:name]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  if (([name isEqualToString:@"write_file"] &&
       (!DSHAgentCanonicalSHA256(precondition[@"relative_path_sha256"]) ||
        !DSHAgentCanonicalSHA256(precondition[@"content_sha256"]) ||
        !DSHAgentSafeInteger(precondition[@"content_bytes"],
                            DSHAgentNativeWALMaxSingleWriteBytes, YES) ||
        ![precondition[@"prior"] isKindOfClass:NSDictionary.class])) ||
      ([name isEqualToString:@"read_file"] &&
       !DSHAgentBoundedUTF8String(precondition[@"source_revision"], 256, NO,
                                 nullptr)) ||
      ([name isEqualToString:@"list_dir"] &&
       !DSHAgentCanonicalSHA256(
           precondition[@"directory_fingerprint_sha256"]))) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  NSString *path = [name isEqualToString:@"list_dir"] && arguments.count == 0
      ? @"" : arguments[@"path"];
  NSArray *components = DSHAgentWorkspacePathComponents(
      path, [name isEqualToString:@"list_dir"]);
  if (components == nil) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  BOOL write = [name isEqualToString:@"write_file"];
  BOOL createParents = write && [precondition[@"schema_version"] isEqual:@3];
  if (createParents && (![precondition[@"prior"][@"kind"] isEqual:@"absent"] ||
      !DSHAgentWorkspaceValidateParentPlan(precondition[@"parent_plan"], components, error))) return nil;
  if (!createParents && precondition[@"parent_plan"] != nil) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument); return nil;
  }
  NSString *agentCapability = write ? @"file_write" : @"file_read";
  if (![root[@"capabilities"] containsObject:agentCapability]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
    return nil;
  }
  if (write) {
    NSData *pathBytes = [path dataUsingEncoding:NSUTF8StringEncoding];
    NSData *contentBytes = [arguments[@"content"]
        dataUsingEncoding:NSUTF8StringEncoding];
    NSString *pathSHA = pathBytes == nil ? nil
        : DSHAgentHB(@"relative-path", pathBytes, error);
    NSString *contentSHA = contentBytes == nil ? nil
        : DSHAgentHB(@"file-content", contentBytes, error);
    if (![pathSHA isEqual:precondition[@"relative_path_sha256"]] ||
        ![contentSHA isEqual:precondition[@"content_sha256"]] ||
        ![@(contentBytes.length) isEqual:precondition[@"content_bytes"]]) {
      DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
      return nil;
    }
  }
  __block NSDictionary *result = nil;
  BOOL succeeded = [self.rootResolver performOperationForFrozenRoot:root
      mode:write ? DSHAgentRootOperationModeWrite
                 : DSHAgentRootOperationModeRead
      timeout:5.0
      block:^BOOL(int rootDescriptor, __unused git_repository *repository,
                  NSError **blockError) {
    if ([name isEqualToString:@"list_dir"]) {
      int directory = DSHAgentWorkspaceOpenDirectory(rootDescriptor, components);
      NSArray *entries = nil;
      NSString *fingerprint = nil;
      BOOL ok = directory >= 0 && [self entryListForDirectoryDescriptor:directory
          entries:&entries fingerprint:&fingerprint error:blockError];
      if (directory >= 0) close(directory);
      if (!ok) return NO;
      if (![fingerprint isEqual:precondition[@"directory_fingerprint_sha256"]]) {
        result = DSHAgentWorkspaceFailure(name, @"E_AGENT_CONFLICT", NO,
                                          blockError);
        return result != nil;
      }
      NSMutableArray *visible = [entries mutableCopy];
      BOOL truncated = NO;
      NSString *feedback = nil;
      while (true) {
        NSDictionary *object = @{
          @"schema_version" : @1, @"name" : name, @"outcome" : @"ok",
          @"payload" : @{
            @"schema_version" : @1, @"entries" : visible,
            @"truncated" : @(truncated),
          },
        };
        feedback = DSHAgentWorkspaceFeedback(object, nil);
        if (feedback != nil || visible.count == 0) break;
        [visible removeLastObject];
        truncated = YES;
      }
      if (feedback == nil) {
        DSHSetAgentNativeStoreError(blockError, DSHAgentNativeStoreErrorCapacity);
        return NO;
      }
      result = @{
        @"schema_version" : @1, @"status" : @"ok",
        @"feedback" : feedback,
        @"settled_facts" : @{
          @"schema_version" : @1, @"kind" : @"list_dir",
          @"directory_fingerprint_sha256" : fingerprint,
        },
        @"truncated" : @(truncated), @"effect_may_have_occurred" : @NO,
      };
      return YES;
    }
    NSString *leaf = components.lastObject;
    DSHAgentWorkspaceParentCreation *parents = createParents
        ? [self parentCreationForRoot:rootDescriptor components:components
            plan:precondition[@"parent_plan"]] : nil;
    int parent = -1;
    if (parents != nil) {
      NSError *parentError = nil;
      if ([parents openParentWithError:&parentError]) parent = [parents duplicateParentDescriptor];
      if (parent < 0) {
        result = DSHAgentWorkspaceWriteFailure(name,
            parentError.code == DSHAgentNativeStoreErrorConflict ? @"E_AGENT_CONFLICT" : @"E_AGENT_TOOL_FAILED",
            NO, parents, blockError);
        return result != nil;
      }
    } else {
      parent = DSHAgentWorkspaceOpenParent(rootDescriptor, components, &leaf);
      if (parent < 0) {
        DSHSetAgentNativeStoreError(blockError, DSHAgentNativeStoreErrorInvalidArgument);
        return NO;
      }
    }
    if ([name isEqualToString:@"read_file"]) {
      int descriptor = openat(parent, leaf.fileSystemRepresentation,
                              O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
      struct stat before = {};
      if (descriptor < 0 || fstat(descriptor, &before) != 0 ||
          !S_ISREG(before.st_mode) || before.st_nlink != 1 ||
          ![DSHAgentWorkspaceRevision(before)
              isEqual:precondition[@"source_revision"]]) {
        if (descriptor >= 0) close(descriptor);
        close(parent);
        result = DSHAgentWorkspaceFailure(name, @"E_AGENT_CONFLICT", NO,
                                          blockError);
        return result != nil;
      }
      NSUInteger wanted = MIN((NSUInteger)MAX((off_t)0, before.st_size),
                              DSHAgentWorkspaceMaxReadBytes);
      NSMutableData *data = [NSMutableData dataWithLength:wanted];
      NSUInteger offset = 0;
      while (offset < wanted) {
        ssize_t count = pread(descriptor,
                              static_cast<uint8_t *>(data.mutableBytes) + offset,
                              wanted - offset, (off_t)offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        offset += (NSUInteger)count;
      }
      [data setLength:offset];
      struct stat after = {};
      BOOL stable = fstat(descriptor, &after) == 0 &&
          [DSHAgentWorkspaceRevision(after)
              isEqual:precondition[@"source_revision"]];
      close(descriptor);
      close(parent);
      NSString *content = stable
          ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
      if (!stable || content == nil) {
        result = DSHAgentWorkspaceFailure(
            name, stable ? @"E_AGENT_TOOL_FAILED" : @"E_AGENT_CONFLICT", NO,
            blockError);
        return result != nil;
      }
      BOOL truncated = before.st_size > (off_t)offset;
      NSMutableDictionary *payload = [@{
        @"schema_version": @1, @"content": content,
        @"revision": precondition[@"source_revision"], @"truncated": @(truncated),
      } mutableCopy];
      if (!truncated) payload[@"sha256"] = DSHAgentWorkspacePlainSHA256(data);
      NSDictionary *object = @{
        @"schema_version" : @1, @"name" : name, @"outcome" : @"ok",
        @"payload" : [payload copy],
      };
      NSString *feedback = DSHAgentWorkspaceFeedback(object, blockError);
      if (feedback == nil) return NO;
      result = @{
        @"schema_version" : @1, @"status" : @"ok", @"feedback" : feedback,
        @"settled_facts" : @{
          @"schema_version" : @1, @"kind" : @"read_file",
          @"source_revision" : precondition[@"source_revision"],
        },
        @"truncated" : @(truncated), @"effect_may_have_occurred" : @NO,
      };
      return YES;
    }
    NSData *content = [arguments[@"content"] dataUsingEncoding:NSUTF8StringEncoding];
    struct stat before = {};
    int statResult = fstatat(parent, leaf.fileSystemRepresentation, &before,
                             AT_SYMLINK_NOFOLLOW);
    int lookupError = errno;
    NSDictionary *actualPrior = statResult == 0
        ? @{ @"schema_version" : @1, @"kind" : @"known",
             @"revision" : DSHAgentWorkspaceRevision(before) }
        : @{ @"schema_version" : @1, @"kind" : @"absent" };
    if ((parents != nil && ![parents validateParentWithError:nil]) ||
        content == nil || ![actualPrior isEqual:precondition[@"prior"]] ||
        (statResult == 0 && (!S_ISREG(before.st_mode) || S_ISLNK(before.st_mode))) ||
        (statResult != 0 && lookupError != ENOENT)) {
      close(parent);
      result = DSHAgentWorkspaceWriteFailure(name, @"E_AGENT_CONFLICT", NO, parents,
                                        blockError);
      return result != nil;
    }
    int existingDescriptor = -1;
    if (statResult == 0) {
      existingDescriptor = openat(parent, leaf.fileSystemRepresentation,
                                  O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
      struct stat opened = {};
      if (existingDescriptor < 0 || fstat(existingDescriptor, &opened) != 0 ||
          before.st_nlink != 1 ||
          !DSHAgentWorkspaceSameFileState(before, opened) ||
          !DSHAgentWorkspaceStatMatches(parent, leaf, before, nullptr)) {
        if (existingDescriptor >= 0) close(existingDescriptor);
        close(parent);
        result = DSHAgentWorkspaceWriteFailure(name, @"E_AGENT_CONFLICT", NO, parents,
                                          blockError);
        return result != nil;
      }
    }
    NSString *temporaryName = [NSString stringWithFormat:@".rish-agent-%@-%@.tmp",
        [precondition[@"relative_path_sha256"] substringToIndex:16],
        [precondition[@"content_sha256"] substringToIndex:16]];
    int temporary = openat(parent, temporaryName.fileSystemRepresentation,
                           O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                           0600);
    BOOL durable = temporary >= 0 && DSHAgentWorkspaceWriteAll(temporary, content) &&
        fsync(temporary) == 0 && fchmod(temporary, 0600) == 0;
    if (temporary >= 0 && close(temporary) != 0) durable = NO;
    if (!durable) {
      if (temporary >= 0) unlinkat(parent, temporaryName.fileSystemRepresentation, 0);
      if (existingDescriptor >= 0) close(existingDescriptor);
      close(parent);
      result = DSHAgentWorkspaceWriteFailure(name, @"E_AGENT_TOOL_FAILED", NO, parents,
                                        blockError);
      return result != nil;
    }
    BOOL createOnly = [precondition[@"prior"][@"kind"]
        isEqualToString:@"absent"];
    BOOL installed = NO;
    if (createOnly) {
      installed = renameatx_np(parent, temporaryName.fileSystemRepresentation,
                               parent, leaf.fileSystemRepresentation,
                               RENAME_EXCL) == 0;
      if (!installed) {
        int renameError = errno;
        unlinkat(parent, temporaryName.fileSystemRepresentation, 0);
        if (existingDescriptor >= 0) close(existingDescriptor);
        close(parent);
        result = DSHAgentWorkspaceWriteFailure(
            name, renameError == EEXIST ? @"E_AGENT_CONFLICT" : @"E_AGENT_TOOL_FAILED",
            NO, parents, blockError);
        return result != nil;
      }
      durable = fsync(parent) == 0;
    } else {
      int replacementDescriptor = openat(
          parent, temporaryName.fileSystemRepresentation,
          O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
      struct stat replacement = {};
      struct stat held = {};
      BOOL replacementValid = replacementDescriptor >= 0 &&
          fstat(replacementDescriptor, &replacement) == 0 &&
          S_ISREG(replacement.st_mode) && replacement.st_nlink == 1;
      BOOL preconditionStillHolds = replacementValid &&
          fstat(existingDescriptor, &held) == 0 &&
          DSHAgentWorkspaceSameFileState(before, held) &&
          DSHAgentWorkspaceStatMatches(parent, leaf, before, nullptr);
      installed = preconditionStillHolds &&
          renameatx_np(parent, temporaryName.fileSystemRepresentation,
                       parent, leaf.fileSystemRepresentation, RENAME_SWAP) == 0;
      struct stat installedState = {};
      struct stat backupState = {};
      BOOL verified = installed &&
          DSHAgentWorkspaceStatMatches(parent, leaf, replacement,
                                       &installedState) &&
          DSHAgentWorkspaceStatMatches(parent, temporaryName, before,
                                       &backupState);
      if (!installed || !verified) {
        if (!installed) unlinkat(parent, temporaryName.fileSystemRepresentation, 0);
        if (replacementDescriptor >= 0) close(replacementDescriptor);
        close(existingDescriptor);
        close(parent);
        result = DSHAgentWorkspaceWriteFailure(
            name, preconditionStillHolds ? @"E_AGENT_TOOL_FAILED" : @"E_AGENT_CONFLICT",
            installed, parents, blockError);
        return result != nil;
      }
      durable = fsync(parent) == 0;
      if (durable &&
          DSHAgentWorkspaceStatMatches(parent, temporaryName, before, nullptr)) {
        if (unlinkat(parent, temporaryName.fileSystemRepresentation, 0) != 0 ||
            fsync(parent) != 0) durable = NO;
      } else {
        durable = NO;
      }
      if (replacementDescriptor >= 0) close(replacementDescriptor);
    }
    if (existingDescriptor >= 0) close(existingDescriptor);
    struct stat after = {};
    BOOL parentStable = parents == nil || [parents validateParentWithError:nil];
    BOOL observed = parentStable && fstatat(parent, leaf.fileSystemRepresentation, &after,
                            AT_SYMLINK_NOFOLLOW) == 0 && S_ISREG(after.st_mode);
    close(parent);
    if (!durable || !observed) {
      result = DSHAgentWorkspaceWriteFailure(
          name, @"E_AGENT_EXECUTION_AMBIGUOUS", YES, parents, blockError);
      return result != nil;
    }
    NSString *revision = DSHAgentWorkspaceRevision(after);
    NSDictionary *object = @{
      @"schema_version" : @1, @"name" : name, @"outcome" : @"ok",
      @"payload" : @{
        @"schema_version" : @1, @"bytes" : @(content.length),
        @"revision" : revision,
        @"sha256" : DSHAgentWorkspacePlainSHA256(content),
      },
    };
    NSString *feedback = DSHAgentWorkspaceFeedback(object, blockError);
    if (feedback == nil) return NO;
    result = @{
      @"schema_version" : @1, @"status" : @"ok", @"feedback" : feedback,
      @"settled_facts" : @{
        @"schema_version" : @1, @"kind" : @"write_file",
        @"actual_revision" : revision,
        @"content_sha256" : precondition[@"content_sha256"],
      },
      @"truncated" : @NO, @"effect_may_have_occurred" : @YES,
    };
    return YES;
  } error:error];
  return succeeded ? result : nil;
}

- (NSDictionary *)recoverToolNamed:(NSString *)name
                          arguments:(NSDictionary *)arguments
                               root:(NSDictionary *)root
                       precondition:(NSDictionary *)precondition
                              error:(NSError **)error {
  if (![name isEqualToString:@"write_file"]) {
    // Read/list are safe to reproduce only after a fresh preflight proves the
    // exact same source revision/fingerprint.
    NSDictionary *fresh = [self prepareToolNamed:name arguments:arguments
                                             root:root error:error];
    if (fresh == nil) return nil;
    return @{
      @"schema_version" : @1,
      @"status" : [fresh[@"precondition"] isEqual:precondition]
          ? @"not_dispatched" : @"ambiguous",
    };
  }
  NSString *path = arguments[@"path"];
  NSArray *components = DSHAgentWorkspacePathComponents(path, NO);
  NSData *content = [arguments[@"content"] dataUsingEncoding:NSUTF8StringEncoding];
  if (components == nil || content == nil) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  BOOL plannedParents = [precondition[@"schema_version"] isEqual:@3];
  if (plannedParents && (![precondition[@"prior"][@"kind"] isEqual:@"absent"] ||
      !DSHAgentWorkspaceValidateParentPlan(precondition[@"parent_plan"], components, error))) return nil;
  __block NSDictionary *result = nil;
  if (![DSHAgentRootResolver validateAgentRootProjection:root error:error]) return nil;
  BOOL succeeded = [self.rootResolver performOperationForFrozenRoot:root
      mode:DSHAgentRootOperationModeWrite timeout:5.0
      block:^BOOL(int rootDescriptor, __unused git_repository *repository,
                  NSError **blockError) {
    (void)blockError;
    if (plannedParents) {
      BOOL stillAbsent = NO;
      if (!DSHAgentWorkspaceParentPlanRemainsAbsent(rootDescriptor, components,
          precondition[@"parent_plan"], &stillAbsent, nil)) {
        result = @{ @"schema_version" : @1, @"status" : @"ambiguous" }; return YES;
      }
      if (stillAbsent) {
        result = @{ @"schema_version" : @1, @"status" : @"not_dispatched" }; return YES;
      }
      // One originally missing parent now exists. Without a matching final
      // file the write may have created directories before a crash; never
      // erase that effect by calling it not dispatched or by cleaning here.
    }
    NSString *leaf = nil;
    int parent = DSHAgentWorkspaceOpenParent(rootDescriptor, components, &leaf);
    struct stat metadata = {};
    int statResult = parent < 0 ? -1 : fstatat(
        parent, leaf.fileSystemRepresentation, &metadata, AT_SYMLINK_NOFOLLOW);
    int lookupError = errno;
    if (statResult != 0 && lookupError == ENOENT &&
        [precondition[@"prior"][@"kind"] isEqualToString:@"absent"]) {
      struct stat recheck = {};
      BOOL stillAbsent = !plannedParents && parent >= 0 &&
          fstatat(parent, leaf.fileSystemRepresentation, &recheck,
                  AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT;
      if (parent >= 0) close(parent);
      result = @{ @"schema_version" : @1,
                  @"status" : stillAbsent ? @"not_dispatched" : @"ambiguous" };
      return YES;
    }
    if (statResult != 0 || !S_ISREG(metadata.st_mode) || metadata.st_nlink != 1) {
      if (parent >= 0) close(parent);
      result = @{ @"schema_version" : @1, @"status" : @"ambiguous" };
      return YES;
    }
    NSString *revision = DSHAgentWorkspaceRevision(metadata);
    if ([precondition[@"prior"][@"kind"] isEqualToString:@"known"] &&
        [precondition[@"prior"][@"revision"] isEqual:revision]) {
      int held = openat(parent, leaf.fileSystemRepresentation,
                        O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
      struct stat opened = {};
      BOOL stable = held >= 0 && fstat(held, &opened) == 0 &&
          DSHAgentWorkspaceSameFileState(metadata, opened) &&
          opened.st_nlink == 1 &&
          DSHAgentWorkspaceStatMatches(parent, leaf, metadata, nullptr);
      if (held >= 0) close(held);
      close(parent);
      result = @{ @"schema_version" : @1,
                  @"status" : stable ? @"not_dispatched" : @"ambiguous" };
      return YES;
    }
    // Recovery reads at most the exact single-write bound and proves the same
    // inode/revision before and after. Oversized or unstable state is ambiguous.
    if (metadata.st_size < 0 ||
        metadata.st_size > (off_t)DSHAgentNativeWALMaxSingleWriteBytes ||
        (NSUInteger)metadata.st_size != content.length) {
      close(parent);
      result = @{ @"schema_version" : @1, @"status" : @"ambiguous" };
      return YES;
    }
    int descriptor = openat(parent, leaf.fileSystemRepresentation,
                            O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    struct stat opened = {};
    BOOL openedStable = descriptor >= 0 && fstat(descriptor, &opened) == 0 &&
        DSHAgentWorkspaceSameFileState(metadata, opened) && opened.st_nlink == 1 &&
        DSHAgentWorkspaceStatMatches(parent, leaf, metadata, nullptr);
    NSMutableData *actual = openedStable
        ? [NSMutableData dataWithLength:(NSUInteger)metadata.st_size] : nil;
    NSUInteger offset = 0;
    while (actual != nil && offset < actual.length) {
      ssize_t count = pread(descriptor,
          static_cast<uint8_t *>(actual.mutableBytes) + offset,
          actual.length - offset, (off_t)offset);
      if (count < 0 && errno == EINTR) continue;
      if (count <= 0) break;
      offset += (NSUInteger)count;
    }
    struct stat after = {};
    BOOL finalStable = actual != nil && offset == actual.length &&
        fstat(descriptor, &after) == 0 &&
        DSHAgentWorkspaceSameFileState(opened, after) && after.st_nlink == 1 &&
        DSHAgentWorkspaceStatMatches(parent, leaf, metadata, nullptr);
    if (descriptor >= 0) close(descriptor);
    close(parent);
    NSString *actualSHA = finalStable
        ? DSHAgentHB(@"file-content", actual, blockError) : nil;
    result = @{ @"schema_version" : @1,
                @"status" : finalStable &&
                    [actualSHA isEqual:precondition[@"content_sha256"]]
                    ? @"settled" : @"ambiguous",
                @"actual_revision" : revision };
    return YES;
  } error:error];
  return succeeded ? result : nil;
}

@end
