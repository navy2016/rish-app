#import "LocalWorkspaceAccess.h"

#import "DSHWorkspaceCanonical.h"

#import <CommonCrypto/CommonDigest.h>
#import <TargetConditionals.h>

#include "rish_agent_core.h"

#include <fcntl.h>
#include <math.h>
#include <sys/stdio.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

NSErrorDomain const DSHLocalWorkspaceAccessErrorDomain =
    @"dev.zseven.rish.local-workspace-access";

static const NSUInteger DSHWorkspaceRegistryMaxBytes = 1024 * 1024;
static const NSUInteger DSHWorkspaceRegistryMaxRecords = 1024;
static const NSUInteger DSHWorkspaceAuthorityMaxBytes = 512 * 1024;
static const NSUInteger DSHWorkspaceBookmarkMaxBytes = 256 * 1024;
static const NSUInteger DSHWorkspaceReceiptStoreMaxBytes = 4 * 1024 * 1024;
static const NSUInteger DSHWorkspaceReceiptCapacity = 2048;
static const NSTimeInterval DSHWorkspaceReceiptTTL = 30 * 24 * 60 * 60;
static const unsigned long long DSHWorkspaceMaxSafeInteger =
    9007199254740991ULL;

// Protection class for everything under local-workspaces/ and
// workspace-bindings/. The store is an index (registry, receipts, authority
// journals, bindings) over Documents-owned workspace files. Every durable
// store the Agent reads while it keeps working on a locked phone after the
// first unlock (sessions.json, agent-runtime/, the workspace files
// themselves) uses CompleteUntilFirstUserAuthentication; AgentRootResolver
// cannot resolve a workspace root without the registry, so the index must not
// be stricter than the data it points at. Earlier builds wrote
// NSFileProtectionComplete; those items are migrated in place on the next
// unlocked access.
static NSString *DSHWorkspaceStoreProtectionClass(void) {
  return NSFileProtectionCompleteUntilFirstUserAuthentication;
}

// YES when `url` carries the store protection class, migrating a legacy
// NSFileProtectionComplete item in place first. CoreSimulator does not report
// NSFileProtectionKey through NSFileManager, so an absent value is accepted
// there only; a physical device must report the exact class.
static BOOL DSHWorkspaceStoreProtectionValidAtURL(NSURL *url) {
  NSDictionary *attributes =
      [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
  id protection = attributes[NSFileProtectionKey];
  if ([protection isEqual:DSHWorkspaceStoreProtectionClass()]) return YES;
  if ([protection isEqual:NSFileProtectionComplete]) {
    if (![NSFileManager.defaultManager
            setAttributes:@{NSFileProtectionKey : DSHWorkspaceStoreProtectionClass()}
             ofItemAtPath:url.path error:nil]) {
      return NO;
    }
    attributes = [NSFileManager.defaultManager attributesOfItemAtPath:url.path
                                                                error:nil];
    return [attributes[NSFileProtectionKey]
        isEqual:DSHWorkspaceStoreProtectionClass()];
  }
#if TARGET_OS_SIMULATOR
  return protection == nil;
#else
  return NO;
#endif
}

static NSString *DSHWorkspacePublicCode(
    DSHLocalWorkspaceAccessErrorCode code) {
  switch (code) {
    case DSHLocalWorkspaceAccessErrorInvalid:
      return @"E_WORKSPACE_INVALID";
    case DSHLocalWorkspaceAccessErrorNotFound:
      return @"E_WORKSPACE_NOT_FOUND";
    case DSHLocalWorkspaceAccessErrorBusy:
      return @"E_WORKSPACE_BUSY";
    case DSHLocalWorkspaceAccessErrorPickerBusy:
      return @"E_WORKSPACE_PICKER_BUSY";
    case DSHLocalWorkspaceAccessErrorSelectionExpired:
      return @"E_WORKSPACE_SELECTION_EXPIRED";
    case DSHLocalWorkspaceAccessErrorRevisionStale:
      return @"E_WORKSPACE_REVISION_STALE";
    case DSHLocalWorkspaceAccessErrorRevisionOverflow:
      return @"E_WORKSPACE_REVISION_OVERFLOW";
    case DSHLocalWorkspaceAccessErrorStatusStale:
      return @"E_WORKSPACE_STATUS_STALE";
    case DSHLocalWorkspaceAccessErrorRevoked:
      return @"E_WORKSPACE_REVOKED";
    case DSHLocalWorkspaceAccessErrorUnavailable:
      return @"E_WORKSPACE_UNAVAILABLE";
    case DSHLocalWorkspaceAccessErrorNotDownloaded:
      return @"E_WORKSPACE_NOT_DOWNLOADED";
    case DSHLocalWorkspaceAccessErrorImportRequired:
      return @"E_WORKSPACE_IMPORT_REQUIRED";
    case DSHLocalWorkspaceAccessErrorCapability:
      return @"E_WORKSPACE_CAPABILITY";
    case DSHLocalWorkspaceAccessErrorRootChanged:
      return @"E_WORKSPACE_ROOT_CHANGED";
    case DSHLocalWorkspaceAccessErrorReferenced:
      return @"E_WORKSPACE_REFERENCED";
    case DSHLocalWorkspaceAccessErrorConfirmation:
      return @"E_WORKSPACE_CONFIRMATION";
    case DSHLocalWorkspaceAccessErrorConflict:
      return @"E_WORKSPACE_CONFLICT";
    case DSHLocalWorkspaceAccessErrorIO:
      return @"E_WORKSPACE_IO";
    case DSHLocalWorkspaceAccessErrorPersistence:
      return @"E_WORKSPACE_PERSISTENCE";
  }
}

static NSString *DSHWorkspacePublicMessage(
    DSHLocalWorkspaceAccessErrorCode code) {
  switch (code) {
    case DSHLocalWorkspaceAccessErrorInvalid:
      return @"Workspace request is invalid.";
    case DSHLocalWorkspaceAccessErrorNotFound:
      return @"Workspace is not available.";
    case DSHLocalWorkspaceAccessErrorBusy:
      return @"Workspace storage is busy.";
    case DSHLocalWorkspaceAccessErrorPickerBusy:
      return @"Another workspace picker operation is active.";
    case DSHLocalWorkspaceAccessErrorSelectionExpired:
      return @"Workspace picker selection has expired.";
    case DSHLocalWorkspaceAccessErrorRevisionStale:
      return @"Workspace binding is stale.";
    case DSHLocalWorkspaceAccessErrorRevisionOverflow:
      return @"Workspace binding cannot be advanced.";
    case DSHLocalWorkspaceAccessErrorStatusStale:
      return @"Workspace authority is stale.";
    case DSHLocalWorkspaceAccessErrorRevoked:
      return @"Workspace authority was revoked.";
    case DSHLocalWorkspaceAccessErrorUnavailable:
      return @"Workspace is unavailable.";
    case DSHLocalWorkspaceAccessErrorNotDownloaded:
      return @"Workspace content is not downloaded.";
    case DSHLocalWorkspaceAccessErrorImportRequired:
      return @"Workspace import is required.";
    case DSHLocalWorkspaceAccessErrorCapability:
      return @"Workspace capability is unavailable.";
    case DSHLocalWorkspaceAccessErrorRootChanged:
      return @"Workspace root changed.";
    case DSHLocalWorkspaceAccessErrorReferenced:
      return @"Workspace is still referenced.";
    case DSHLocalWorkspaceAccessErrorConfirmation:
      return @"Workspace confirmation is invalid.";
    case DSHLocalWorkspaceAccessErrorConflict:
      return @"Workspace storage changed concurrently.";
    case DSHLocalWorkspaceAccessErrorIO:
      return @"Workspace operation failed.";
    case DSHLocalWorkspaceAccessErrorPersistence:
      return @"Workspace storage is invalid.";
  }
}

static NSError *DSHWorkspaceError(DSHLocalWorkspaceAccessErrorCode code) {
  return [NSError errorWithDomain:DSHLocalWorkspaceAccessErrorDomain
                             code:code
                         userInfo:@{
                           @"code" : DSHWorkspacePublicCode(code),
                           NSLocalizedDescriptionKey :
                               DSHWorkspacePublicMessage(code),
                         }];
}

static void DSHSetWorkspaceError(NSError **error,
                                 DSHLocalWorkspaceAccessErrorCode code) {
  if (error != nil) *error = DSHWorkspaceError(code);
}

static BOOL DSHExactKeys(NSDictionary *dictionary,
                         NSArray<NSString *> *keys) {
  if (![dictionary isKindOfClass:NSDictionary.class] ||
      dictionary.count != keys.count) {
    return NO;
  }
  NSSet *allowed = [NSSet setWithArray:keys];
  for (id key in dictionary) {
    if (![key isKindOfClass:NSString.class] || ![allowed containsObject:key]) {
      return NO;
    }
  }
  return YES;
}

static BOOL DSHIsBooleanNumber(id value) {
  return [value isKindOfClass:NSNumber.class] &&
         CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL DSHSchemaVersionIsOne(id value) {
  return [value isKindOfClass:NSNumber.class] &&
         !DSHIsBooleanNumber(value) && [value isEqual:@1];
}

static BOOL DSHIsSafeInteger(id value, BOOL allowZero) {
  if (![value isKindOfClass:NSNumber.class] || DSHIsBooleanNumber(value)) {
    return NO;
  }
  double number = [value doubleValue];
  if (!isfinite(number) || floor(number) != number || number < 0 ||
      number > (double)DSHWorkspaceMaxSafeInteger ||
      (number == 0 && signbit(number)) || (!allowZero && number == 0)) {
    return NO;
  }
  return YES;
}

BOOL DSHLocalWorkspaceValidateBindingRevisionAdvance(
    NSNumber *currentRevision,
    NSNumber *proposedRevision,
    NSError **error) {
  if (!DSHIsSafeInteger(currentRevision, NO) ||
      !DSHIsSafeInteger(proposedRevision, NO)) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorInvalid);
    return NO;
  }
  unsigned long long current = currentRevision.unsignedLongLongValue;
  if (current >= DSHWorkspaceMaxSafeInteger) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorRevisionOverflow);
    return NO;
  }
  if (proposedRevision.unsignedLongLongValue != current + 1) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorConflict);
    return NO;
  }
  return YES;
}

static BOOL DSHMatches(NSString *value, NSString *pattern) {
  if (![value isKindOfClass:NSString.class]) return NO;
  NSRegularExpression *expression =
      [NSRegularExpression regularExpressionWithPattern:pattern
                                                options:0
                                                  error:nil];
  if (expression == nil) return NO;
  NSRange full = NSMakeRange(0, value.length);
  NSTextCheckingResult *match = [expression firstMatchInString:value
                                                       options:0
                                                         range:full];
  return match != nil && NSEqualRanges(match.range, full);
}

static BOOL DSHCanonicalUUID(id value) {
  if (![value isKindOfClass:NSString.class] ||
      !DSHMatches(value,
          @"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-"
           "[0-9a-f]{12}$")) {
    return NO;
  }
  NSUUID *UUID = [[NSUUID alloc] initWithUUIDString:value];
  return UUID != nil && [UUID.UUIDString.lowercaseString isEqual:value];
}

static BOOL DSHCanonicalSHA256(id value) {
  return [value isKindOfClass:NSString.class] &&
         DSHMatches(value, @"^[0-9a-f]{64}$");
}

static NSISO8601DateFormatter *DSHTimestampFormatter(void) {
  NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
  formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                            NSISO8601DateFormatWithFractionalSeconds;
  formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
  return formatter;
}

static BOOL DSHCanonicalTimestamp(id value) {
  if (![value isKindOfClass:NSString.class] ||
      !DSHMatches(value,
          @"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:"
           "[0-9]{2}\\.[0-9]{3}Z$")) {
    return NO;
  }
  NSISO8601DateFormatter *formatter = DSHTimestampFormatter();
  NSDate *date = [formatter dateFromString:value];
  return date != nil && [[formatter stringFromDate:date] isEqual:value];
}

static NSString *DSHCanonicalTimestampForDate(NSDate *date) {
  if (![date isKindOfClass:NSDate.class]) return nil;
  return [DSHTimestampFormatter() stringFromDate:date];
}

static BOOL DSHCanonicalUnsignedIntegerString(id value) {
  if (![value isKindOfClass:NSString.class]) return NO;
  NSString *string = value;
  if (string.length == 0 || string.length > 20 ||
      !DSHMatches(string, @"^(0|[1-9][0-9]*)$")) {
    return NO;
  }
  errno = 0;
  (void)strtoull(string.UTF8String, nullptr, 10);
  return errno != ERANGE;
}

static BOOL DSHCanonicalPositiveIntegerString(id value) {
  return DSHCanonicalUnsignedIntegerString(value) && ![value isEqual:@"0"];
}

static BOOL DSHCanonicalCapabilitiesSet(id value);
static BOOL DSHCanonicalDisplayName(id value);

static BOOL DSHValidLegacyEvidence(NSDictionary *identity,
                                   NSString *expectedProjectId) {
  NSArray *keys = @[
    @"project_id", @"display_name", @"metadata_sha256", @"capabilities",
    @"projects_root_device_id",
    @"projects_root_inode_id", @"repository_device_id",
    @"repository_inode_id", @"git_device_id", @"git_inode_id",
  ];
  return DSHExactKeys(identity, keys) &&
      [identity[@"project_id"] isEqual:expectedProjectId] &&
      DSHCanonicalDisplayName(identity[@"display_name"]) &&
      DSHCanonicalSHA256(identity[@"metadata_sha256"]) &&
      DSHCanonicalCapabilitiesSet(identity[@"capabilities"]) &&
      DSHCanonicalPositiveIntegerString(identity[@"projects_root_device_id"]) &&
      DSHCanonicalPositiveIntegerString(identity[@"projects_root_inode_id"]) &&
      DSHCanonicalPositiveIntegerString(identity[@"repository_device_id"]) &&
      DSHCanonicalPositiveIntegerString(identity[@"repository_inode_id"]) &&
      DSHCanonicalPositiveIntegerString(identity[@"git_device_id"]) &&
      DSHCanonicalPositiveIntegerString(identity[@"git_inode_id"]);
}

static BOOL DSHValidLegacyPhysicalIdentity(NSDictionary *identity,
                                           NSString *expectedMetadata) {
  NSArray *keys = @[
    @"project_metadata_sha256", @"projects_root_device_id",
    @"projects_root_inode_id", @"repository_device_id",
    @"repository_inode_id", @"git_device_id", @"git_inode_id",
  ];
  return DSHExactKeys(identity, keys) &&
      [identity[@"project_metadata_sha256"] isEqual:expectedMetadata] &&
      DSHCanonicalSHA256(identity[@"project_metadata_sha256"]) &&
      DSHCanonicalPositiveIntegerString(identity[@"projects_root_device_id"]) &&
      DSHCanonicalPositiveIntegerString(identity[@"projects_root_inode_id"]) &&
      DSHCanonicalPositiveIntegerString(identity[@"repository_device_id"]) &&
      DSHCanonicalPositiveIntegerString(identity[@"repository_inode_id"]) &&
      DSHCanonicalPositiveIntegerString(identity[@"git_device_id"]) &&
      DSHCanonicalPositiveIntegerString(identity[@"git_inode_id"]);
}

static BOOL DSHLegacyPhysicalIdentityMatchesAuthority(
    NSDictionary *identity,
    NSDictionary *authority) {
  // Device ids are deliberately absent: iOS renumbers the data volume across
  // reboots, so a persisted st_dev is not evidence about the directory. The
  // three inodes, all reached from this app's own container, carry the
  // identity.
  NSArray *keys = @[
    @"projects_root_inode_id", @"repository_inode_id", @"git_inode_id",
  ];
  for (NSString *key in keys) {
    if (![identity[key] isEqual:authority[key]]) return NO;
  }
  return YES;
}

static BOOL DSHCanonicalDisplayName(id value) {
  if (![value isKindOfClass:NSString.class]) return NO;
  NSString *name = value;
  NSString *normalized = [name precomposedStringWithCanonicalMapping];
  if (![normalized isEqual:name]) return NO;
  NSData *bytes = [name dataUsingEncoding:NSUTF8StringEncoding
                     allowLossyConversion:NO];
  if (bytes.length == 0 || bytes.length > 120) return NO;
  NSString *trimmed = [name
      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (![trimmed isEqual:name] || [name hasPrefix:@"."] ||
      [name isEqual:@"."] || [name isEqual:@".."] ||
      [name rangeOfString:@"/"].location != NSNotFound ||
      [name rangeOfString:@"\\"].location != NSNotFound ||
      [name rangeOfString:@":"].location != NSNotFound ||
      [name rangeOfString:@"\0"].location != NSNotFound ||
      [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location !=
          NSNotFound) {
    return NO;
  }
  NSString *folded = [name stringByFoldingWithOptions:
      NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch
                                           locale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
  return ![folded isEqual:@"rish workspaces"] &&
         ![folded hasPrefix:@".rish-"];
}

static BOOL DSHSafeDirectoryName(id value) {
  return DSHCanonicalDisplayName(value);
}

// Which grants a locator kind implies, and how they are projected, live in the
// shared core (modules/rish/core, `rish_agent_workspace_grants_reduce`).
// Deriving the *status* stays here: it resolves a security-scoped bookmark,
// starts a scope and stats a directory, none of which travels. What a status
// means does travel.
static NSDictionary *DSHWorkspaceGrantsReduce(NSString *op,
                                              NSDictionary *fields) {
  NSMutableDictionary *envelope = [fields mutableCopy];
  envelope[@"op"] = op;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:envelope options:0
                                                    error:nil];
  char *raw = bytes == nil ? NULL : rish_agent_workspace_grants_reduce(
      (const char *)bytes.bytes, bytes.length);
  if (raw == NULL) return nil;
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0
                                                error:nil];
  return [reply isKindOfClass:NSDictionary.class] &&
      [reply[@"ok"] isEqual:@YES] ? reply : nil;
}

static NSString *DSHSHA256(NSData *data) {
  return DSHWorkspaceSHA256Hex(data);
}

static NSData *DSHCanonicalJSON(id object) {
  return DSHWorkspaceCanonicalJSONData(object, nil);
}

static NSString *DSHAuthorityDigestWithoutFingerprint(
    NSDictionary *authority) {
  if (![authority isKindOfClass:NSDictionary.class]) return nil;
  NSMutableDictionary *base = [authority mutableCopy];
  [base removeObjectForKey:@"root_fingerprint_sha256"];
  return DSHSHA256(DSHCanonicalJSON(base));
}

static NSDictionary *DSHDocumentsOwnedFingerprintInput(
    NSDictionary *record,
    NSDictionary *authority,
    NSString *authorityDigest) {
  if (![record isKindOfClass:NSDictionary.class] ||
      ![authority isKindOfClass:NSDictionary.class] ||
      ![authorityDigest isKindOfClass:NSString.class]) {
    return nil;
  }
  return @{
    @"schema_version" : @1,
    @"origin" : record[@"origin"],
    @"workspace_id" : record[@"workspace_id"],
    @"binding_revision" : record[@"binding_revision"],
    @"root_locator_kind" : @"documents_owned",
    @"device_id" : authority[@"device_id"],
    @"inode_id" : authority[@"inode_id"],
    @"directory_name_sha256" : authority[@"directory_name_sha256"],
    @"authority_sha256" : authorityDigest,
  };
}

static BOOL DSHValidDocumentsOwnedFingerprint(NSDictionary *authority,
                                              NSDictionary *record) {
  NSString *fingerprint = authority[@"root_fingerprint_sha256"];
  if (!DSHCanonicalSHA256(fingerprint)) return NO;
  NSString *authorityDigest = DSHAuthorityDigestWithoutFingerprint(authority);
  NSDictionary *input = DSHDocumentsOwnedFingerprintInput(record, authority,
                                                          authorityDigest);
  NSString *expected = DSHWorkspaceRootFingerprintSHA256(input, nil);
  return expected != nil && [fingerprint isEqual:expected];
}

static NSDictionary *DSHGrantedFingerprintInput(NSDictionary *record,
                                                NSDictionary *authority,
                                                NSString *authorityDigest) {
  if (![record isKindOfClass:NSDictionary.class] ||
      ![authority isKindOfClass:NSDictionary.class] ||
      ![authorityDigest isKindOfClass:NSString.class]) {
    return nil;
  }
  return @{
    @"schema_version" : @1,
    @"origin" : record[@"origin"],
    @"workspace_id" : record[@"workspace_id"],
    @"binding_revision" : record[@"binding_revision"],
    @"root_locator_kind" : @"security_scoped",
    @"volume_identifier_sha256" : authority[@"volume_identifier_sha256"],
    @"resource_identifier_sha256" : authority[@"resource_identifier_sha256"],
    @"device_id" : authority[@"device_id"],
    @"inode_id" : authority[@"inode_id"],
    @"bookmark_sha256" : authority[@"bookmark_sha256"],
    @"authority_sha256" : authorityDigest,
  };
}

static BOOL DSHValidGrantedFingerprint(NSDictionary *authority,
                                       NSDictionary *record) {
  NSString *fingerprint = authority[@"root_fingerprint_sha256"];
  if (!DSHCanonicalSHA256(fingerprint)) return NO;
  NSString *authorityDigest = DSHAuthorityDigestWithoutFingerprint(authority);
  NSDictionary *input = DSHGrantedFingerprintInput(record, authority,
                                                   authorityDigest);
  NSString *expected = DSHWorkspaceRootFingerprintSHA256(input, nil);
  return expected != nil && [fingerprint isEqual:expected];
}

static NSDictionary *DSHLegacyFingerprintInput(NSDictionary *record,
                                               NSDictionary *authority,
                                               NSString *authorityDigest) {
  if (![record isKindOfClass:NSDictionary.class] ||
      ![authority isKindOfClass:NSDictionary.class] ||
      ![authorityDigest isKindOfClass:NSString.class]) {
    return nil;
  }
  return @{
    @"schema_version" : @1,
    @"origin" : record[@"origin"],
    @"workspace_id" : record[@"workspace_id"],
    @"binding_revision" : record[@"binding_revision"],
    @"root_locator_kind" : @"legacy_app_owned",
    @"legacy_project_id" : authority[@"legacy_project_id"],
    @"project_metadata_sha256" : authority[@"project_metadata_sha256"],
    @"projects_root_device_id" : authority[@"projects_root_device_id"],
    @"projects_root_inode_id" : authority[@"projects_root_inode_id"],
    @"repository_device_id" : authority[@"repository_device_id"],
    @"repository_inode_id" : authority[@"repository_inode_id"],
    @"git_device_id" : authority[@"git_device_id"],
    @"git_inode_id" : authority[@"git_inode_id"],
  };
}

static BOOL DSHValidLegacyFingerprint(NSDictionary *authority,
                                      NSDictionary *record) {
  NSString *fingerprint = authority[@"root_fingerprint_sha256"];
  if (!DSHCanonicalSHA256(fingerprint)) return NO;
  NSString *authorityDigest = DSHAuthorityDigestWithoutFingerprint(authority);
  NSDictionary *input = DSHLegacyFingerprintInput(record, authority,
                                                  authorityDigest);
  NSString *expected = DSHWorkspaceRootFingerprintSHA256(input, nil);
  return expected != nil && [fingerprint isEqual:expected];
}

static NSDictionary *DSHMigrateOwnedAuthority(NSDictionary *authority,
                                              NSDictionary *record) {
  NSArray *keys = @[
    @"schema_version", @"workspace_id", @"binding_revision", @"device_id",
    @"inode_id", @"directory_name_sha256", @"recorded_at",
  ];
  NSString *directoryName = record[@"owned_directory_name"];
  NSData *directoryBytes =
      [directoryName dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
  if (!DSHExactKeys(authority, keys) ||
      !DSHSchemaVersionIsOne(authority[@"schema_version"]) ||
      ![authority[@"workspace_id"] isEqual:record[@"workspace_id"]] ||
      ![authority[@"binding_revision"] isEqual:record[@"binding_revision"]] ||
      !DSHCanonicalUnsignedIntegerString(authority[@"device_id"]) ||
      !DSHCanonicalUnsignedIntegerString(authority[@"inode_id"]) ||
      ![authority[@"directory_name_sha256"] isEqual:DSHSHA256(directoryBytes)] ||
      !DSHCanonicalTimestamp(authority[@"recorded_at"])) {
    return nil;
  }
  NSMutableDictionary *migrated = [authority mutableCopy];
  NSString *authorityDigest = DSHAuthorityDigestWithoutFingerprint(authority);
  NSDictionary *input = DSHDocumentsOwnedFingerprintInput(record, authority,
                                                          authorityDigest);
  NSString *fingerprint = DSHWorkspaceRootFingerprintSHA256(input, nil);
  if (fingerprint == nil) return nil;
  migrated[@"root_fingerprint_sha256"] = fingerprint;
  return migrated;
}

static NSDictionary *DSHMigrateGrantedAuthority(NSDictionary *authority,
                                                NSDictionary *record,
                                                NSDictionary *bookmark) {
  NSArray *keys = @[
    @"schema_version", @"workspace_id", @"binding_revision",
    @"volume_identifier_sha256", @"resource_identifier_sha256", @"device_id",
    @"inode_id", @"bookmark_sha256", @"classified_at",
  ];
  if (!DSHExactKeys(authority, keys) ||
      !DSHSchemaVersionIsOne(authority[@"schema_version"]) ||
      ![authority[@"workspace_id"] isEqual:record[@"workspace_id"]] ||
      ![authority[@"binding_revision"] isEqual:record[@"binding_revision"]] ||
      !DSHCanonicalSHA256(authority[@"volume_identifier_sha256"]) ||
      !DSHCanonicalSHA256(authority[@"resource_identifier_sha256"]) ||
      !DSHCanonicalUnsignedIntegerString(authority[@"device_id"]) ||
      !DSHCanonicalUnsignedIntegerString(authority[@"inode_id"]) ||
      ![authority[@"bookmark_sha256"] isEqual:bookmark[@"bookmark_sha256"]] ||
      !DSHCanonicalTimestamp(authority[@"classified_at"])) {
    return nil;
  }
  NSMutableDictionary *migrated = [authority mutableCopy];
  NSString *authorityDigest = DSHAuthorityDigestWithoutFingerprint(authority);
  NSDictionary *input = DSHGrantedFingerprintInput(record, authority,
                                                   authorityDigest);
  NSString *fingerprint = DSHWorkspaceRootFingerprintSHA256(input, nil);
  if (fingerprint == nil) return nil;
  migrated[@"root_fingerprint_sha256"] = fingerprint;
  return migrated;
}

static NSDictionary *DSHMigrateLegacyAuthority(NSDictionary *authority,
                                               NSDictionary *record,
                                               NSDictionary *physicalIdentity) {
  NSArray *keys = @[
    @"schema_version", @"workspace_id", @"binding_revision",
    @"legacy_project_id", @"root_identity_sha256", @"display_name",
    @"created_at", @"last_opened_at", @"recorded_at",
  ];
  if (!DSHExactKeys(authority, keys) ||
      !DSHSchemaVersionIsOne(authority[@"schema_version"]) ||
      ![authority[@"workspace_id"] isEqual:record[@"workspace_id"]] ||
      ![authority[@"binding_revision"] isEqual:record[@"binding_revision"]] ||
      ![authority[@"legacy_project_id"] isEqual:record[@"legacy_project_id"]] ||
      !DSHCanonicalSHA256(authority[@"root_identity_sha256"]) ||
      ![authority[@"display_name"] isEqual:record[@"display_name"]] ||
      !DSHCanonicalTimestamp(authority[@"created_at"]) ||
      !DSHCanonicalTimestamp(authority[@"last_opened_at"]) ||
      !DSHCanonicalTimestamp(authority[@"recorded_at"])) {
    return nil;
  }
  if (!DSHValidLegacyPhysicalIdentity(
          physicalIdentity, authority[@"root_identity_sha256"])) {
    return nil;
  }
  NSMutableDictionary *migrated = [authority mutableCopy];
  [migrated addEntriesFromDictionary:physicalIdentity];
  NSString *authorityDigest = DSHAuthorityDigestWithoutFingerprint(migrated);
  NSDictionary *input = DSHLegacyFingerprintInput(record, migrated,
                                                  authorityDigest);
  NSString *fingerprint = DSHWorkspaceRootFingerprintSHA256(input, nil);
  if (fingerprint == nil) return nil;
  migrated[@"root_fingerprint_sha256"] = fingerprint;
  return migrated;
}

// Request digests are persisted in private authority records so an operation
// id cannot be replayed with a different user request.  Keep the digest input
// deliberately small and value-free: the raw request never crosses the
// native/JS boundary or appears in a receipt.
static NSString *DSHCreateRequestSHA256(NSString *displayName) {
  return DSHSHA256(DSHCanonicalJSON(@{
    @"operation" : @"create",
    @"display_name" : displayName,
  }));
}

static NSString *DSHBootstrapRequestSHA256(NSString *projectId) {
  return DSHSHA256(DSHCanonicalJSON(@{
    @"schema_version" : @1,
    @"operation" : @"bootstrap_legacy",
    @"project_id" : projectId,
  }));
}

static void DSHJSONSkipWhitespace(const uint8_t *bytes,
                                  NSUInteger length,
                                  NSUInteger *index) {
  while (*index < length) {
    uint8_t byte = bytes[*index];
    if (byte != ' ' && byte != '\t' && byte != '\r' && byte != '\n') break;
    *index += 1;
  }
}

static NSString *DSHJSONScanString(const uint8_t *bytes,
                                   NSUInteger length,
                                   NSUInteger *index) {
  if (*index >= length || bytes[*index] != '"') return nil;
  NSUInteger start = *index;
  *index += 1;
  BOOL escaped = NO;
  while (*index < length) {
    uint8_t byte = bytes[*index];
    if (!escaped && byte == '"') {
      *index += 1;
      NSData *token = [NSData dataWithBytes:bytes + start
                                     length:*index - start];
      id decoded = [NSJSONSerialization JSONObjectWithData:token
          options:NSJSONReadingFragmentsAllowed error:nil];
      return [decoded isKindOfClass:NSString.class] ? decoded : nil;
    }
    if (!escaped && byte < 0x20) return nil;
    if (!escaped && byte == '\\') {
      escaped = YES;
    } else {
      escaped = NO;
    }
    *index += 1;
  }
  return nil;
}

static BOOL DSHJSONScanValue(const uint8_t *bytes,
                             NSUInteger length,
                             NSUInteger *index,
                             NSUInteger depth,
                             NSUInteger *nodes);

static BOOL DSHJSONScanObject(const uint8_t *bytes,
                              NSUInteger length,
                              NSUInteger *index,
                              NSUInteger depth,
                              NSUInteger *nodes) {
  *index += 1;
  DSHJSONSkipWhitespace(bytes, length, index);
  if (*index < length && bytes[*index] == '}') {
    *index += 1;
    return YES;
  }
  NSMutableSet<NSString *> *keys = [NSMutableSet set];
  while (*index < length) {
    NSString *key = DSHJSONScanString(bytes, length, index);
    if (key == nil || [keys containsObject:key]) return NO;
    [keys addObject:key];
    DSHJSONSkipWhitespace(bytes, length, index);
    if (*index >= length || bytes[*index] != ':') return NO;
    *index += 1;
    if (!DSHJSONScanValue(bytes, length, index, depth + 1, nodes)) return NO;
    DSHJSONSkipWhitespace(bytes, length, index);
    if (*index < length && bytes[*index] == '}') {
      *index += 1;
      return YES;
    }
    if (*index >= length || bytes[*index] != ',') return NO;
    *index += 1;
    DSHJSONSkipWhitespace(bytes, length, index);
  }
  return NO;
}

static BOOL DSHJSONScanArray(const uint8_t *bytes,
                             NSUInteger length,
                             NSUInteger *index,
                             NSUInteger depth,
                             NSUInteger *nodes) {
  *index += 1;
  DSHJSONSkipWhitespace(bytes, length, index);
  if (*index < length && bytes[*index] == ']') {
    *index += 1;
    return YES;
  }
  while (*index < length) {
    if (!DSHJSONScanValue(bytes, length, index, depth + 1, nodes)) return NO;
    DSHJSONSkipWhitespace(bytes, length, index);
    if (*index < length && bytes[*index] == ']') {
      *index += 1;
      return YES;
    }
    if (*index >= length || bytes[*index] != ',') return NO;
    *index += 1;
    DSHJSONSkipWhitespace(bytes, length, index);
  }
  return NO;
}

static BOOL DSHJSONScanValue(const uint8_t *bytes,
                             NSUInteger length,
                             NSUInteger *index,
                             NSUInteger depth,
                             NSUInteger *nodes) {
  if (depth > 64 || *nodes >= 100000) return NO;
  *nodes += 1;
  DSHJSONSkipWhitespace(bytes, length, index);
  if (*index >= length) return NO;
  if (bytes[*index] == '{') {
    return DSHJSONScanObject(bytes, length, index, depth, nodes);
  }
  if (bytes[*index] == '[') {
    return DSHJSONScanArray(bytes, length, index, depth, nodes);
  }
  if (bytes[*index] == '"') {
    return DSHJSONScanString(bytes, length, index) != nil;
  }
  NSUInteger start = *index;
  while (*index < length) {
    uint8_t byte = bytes[*index];
    if (byte == ',' || byte == ']' || byte == '}' || byte == ' ' ||
        byte == '\t' || byte == '\r' || byte == '\n') {
      break;
    }
    *index += 1;
  }
  if (*index == start) return NO;
  NSData *token = [NSData dataWithBytes:bytes + start length:*index - start];
  NSString *tokenText = [[NSString alloc] initWithData:token
                                               encoding:NSUTF8StringEncoding];
  id decoded = [NSJSONSerialization JSONObjectWithData:token
      options:NSJSONReadingFragmentsAllowed error:nil];
  if (decoded == nil) return NO;
  if ([tokenText hasPrefix:@"-"] && [decoded isKindOfClass:NSNumber.class] &&
      [decoded doubleValue] == 0) {
    return NO;
  }
  return YES;
}

static BOOL DSHJSONHasBoundedExactStructure(NSData *data) {
  if (![data isKindOfClass:NSData.class] || data.length == 0) return NO;
  const uint8_t *bytes = (const uint8_t *)data.bytes;
  NSUInteger index = 0;
  NSUInteger nodes = 0;
  if (!DSHJSONScanValue(bytes, data.length, &index, 1, &nodes)) return NO;
  DSHJSONSkipWhitespace(bytes, data.length, &index);
  return index == data.length;
}

static NSArray<NSString *> *DSHCapabilityOrder(void) {
  return @[@"read", @"write", @"git", @"project_context"];
}

static BOOL DSHCanonicalCapabilitiesArray(id value) {
  if (![value isKindOfClass:NSArray.class] || [value count] > 4) return NO;
  NSArray *array = value;
  NSArray *order = DSHCapabilityOrder();
  NSInteger previous = -1;
  NSMutableSet *seen = [NSMutableSet set];
  for (id item in array) {
    if (![item isKindOfClass:NSString.class] || [seen containsObject:item]) {
      return NO;
    }
    NSUInteger index = [order indexOfObject:item];
    if (index == NSNotFound || (NSInteger)index <= previous) return NO;
    [seen addObject:item];
    previous = (NSInteger)index;
  }
  return YES;
}

static BOOL DSHCanonicalCapabilitiesSet(id value) {
  if (![value isKindOfClass:NSSet.class] || [value count] > 4) return NO;
  NSSet *allowed = [NSSet setWithArray:DSHCapabilityOrder()];
  for (id item in value) {
    if (![item isKindOfClass:NSString.class] || ![allowed containsObject:item]) {
      return NO;
    }
  }
  return YES;
}

static BOOL DSHValidWorkspaceRecord(NSDictionary *record) {
  NSArray *keys = @[
    @"schema_version", @"workspace_id", @"display_name", @"origin",
    @"root_locator_kind", @"location_class", @"owned_directory_name",
    @"legacy_project_id", @"binding_revision", @"created_at",
    @"last_opened_at",
  ];
  if (!DSHExactKeys(record, keys) ||
      !DSHSchemaVersionIsOne(record[@"schema_version"]) ||
      !DSHCanonicalUUID(record[@"workspace_id"]) ||
      !DSHCanonicalDisplayName(record[@"display_name"]) ||
      !DSHIsSafeInteger(record[@"binding_revision"], NO) ||
      !DSHCanonicalTimestamp(record[@"created_at"]) ||
      !DSHCanonicalTimestamp(record[@"last_opened_at"])) {
    return NO;
  }
  NSString *origin = record[@"origin"];
  NSString *locator = record[@"root_locator_kind"];
  NSString *locationClass = record[@"location_class"];
  id owned = record[@"owned_directory_name"];
  id legacy = record[@"legacy_project_id"];
  if ([origin isEqual:@"rish_created"] || [origin isEqual:@"imported"]) {
    return [locator isEqual:@"documents_owned"] &&
           [locationClass isEqual:@"rish_owned"] &&
           DSHSafeDirectoryName(owned) && legacy == NSNull.null;
  }
  if ([origin isEqual:@"granted_folder"]) {
    return [locator isEqual:@"security_scoped"] &&
           [locationClass isEqual:@"proven_local"] &&
           owned == NSNull.null && legacy == NSNull.null;
  }
  if ([origin isEqual:@"legacy_app_owned"]) {
    return [locator isEqual:@"legacy_app_owned"] &&
           [locationClass isEqual:@"rish_owned"] &&
           owned == NSNull.null && DSHCanonicalUUID(legacy);
  }
  return NO;
}

static BOOL DSHValidLegacyAuthority(NSDictionary *authority,
                                    NSDictionary *record) {
  NSArray *keys = @[
    @"schema_version", @"workspace_id", @"binding_revision",
    @"legacy_project_id", @"root_identity_sha256", @"display_name",
    @"capabilities", @"created_at", @"last_opened_at", @"recorded_at",
    @"project_metadata_sha256", @"projects_root_device_id",
    @"projects_root_inode_id", @"repository_device_id",
    @"repository_inode_id", @"git_device_id", @"git_inode_id",
    @"root_fingerprint_sha256",
  ];
  return DSHExactKeys(authority, keys) &&
      DSHSchemaVersionIsOne(authority[@"schema_version"]) &&
      [authority[@"workspace_id"] isEqual:record[@"workspace_id"]] &&
      [authority[@"binding_revision"] isEqual:record[@"binding_revision"]] &&
      [authority[@"legacy_project_id"] isEqual:record[@"legacy_project_id"]] &&
      DSHCanonicalSHA256(authority[@"root_identity_sha256"]) &&
      [authority[@"display_name"] isEqual:record[@"display_name"]] &&
      DSHCanonicalCapabilitiesArray(authority[@"capabilities"]) &&
      [authority[@"created_at"] isEqual:record[@"created_at"]] &&
      [authority[@"last_opened_at"] isEqual:record[@"last_opened_at"]] &&
      DSHCanonicalTimestamp(authority[@"recorded_at"]) &&
      DSHCanonicalSHA256(authority[@"project_metadata_sha256"]) &&
      DSHCanonicalPositiveIntegerString(authority[@"projects_root_device_id"]) &&
      DSHCanonicalPositiveIntegerString(authority[@"projects_root_inode_id"]) &&
      DSHCanonicalPositiveIntegerString(authority[@"repository_device_id"]) &&
      DSHCanonicalPositiveIntegerString(authority[@"repository_inode_id"]) &&
      DSHCanonicalPositiveIntegerString(authority[@"git_device_id"]) &&
      DSHCanonicalPositiveIntegerString(authority[@"git_inode_id"]) &&
      DSHValidLegacyFingerprint(authority, record);
}

static BOOL DSHValidOwnedAuthority(NSDictionary *authority,
                                   NSDictionary *record) {
  NSArray *keys = @[
    @"schema_version", @"workspace_id", @"binding_revision", @"device_id",
    @"inode_id", @"directory_name_sha256", @"recorded_at",
    @"root_fingerprint_sha256",
  ];
  BOOL exactShape = DSHExactKeys(authority, keys);
  NSString *directoryName = record[@"owned_directory_name"];
  NSData *directoryBytes =
      [directoryName dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
  return exactShape &&
      DSHSchemaVersionIsOne(authority[@"schema_version"]) &&
      [authority[@"workspace_id"] isEqual:record[@"workspace_id"]] &&
      [authority[@"binding_revision"] isEqual:record[@"binding_revision"]] &&
      DSHCanonicalUnsignedIntegerString(authority[@"device_id"]) &&
      DSHCanonicalUnsignedIntegerString(authority[@"inode_id"]) &&
      [authority[@"directory_name_sha256"] isEqual:DSHSHA256(directoryBytes)] &&
      DSHCanonicalTimestamp(authority[@"recorded_at"]) &&
      DSHValidDocumentsOwnedFingerprint(authority, record);
}

static BOOL DSHValidBookmarkAuthority(NSDictionary *authority,
                                      NSDictionary *record) {
  NSArray *keys = @[
    @"schema_version", @"workspace_id", @"binding_revision",
    @"bookmark_sha256", @"bookmark_bytes_base64", @"recorded_at",
  ];
  if (!DSHExactKeys(authority, keys) ||
      !DSHSchemaVersionIsOne(authority[@"schema_version"]) ||
      ![authority[@"workspace_id"] isEqual:record[@"workspace_id"]] ||
      ![authority[@"binding_revision"] isEqual:record[@"binding_revision"]] ||
      !DSHCanonicalSHA256(authority[@"bookmark_sha256"]) ||
      ![authority[@"bookmark_bytes_base64"] isKindOfClass:NSString.class] ||
      !DSHCanonicalTimestamp(authority[@"recorded_at"])) {
    return NO;
  }
  NSData *bookmark = [[NSData alloc]
      initWithBase64EncodedString:authority[@"bookmark_bytes_base64"]
                          options:0];
  return bookmark != nil && bookmark.length <= DSHWorkspaceBookmarkMaxBytes &&
         [authority[@"bookmark_sha256"] isEqual:DSHSHA256(bookmark)];
}

static BOOL DSHValidGrantedAuthority(NSDictionary *authority,
                                     NSDictionary *record,
                                     NSDictionary *bookmark) {
  NSArray *keys = @[
    @"schema_version", @"workspace_id", @"binding_revision",
    @"volume_identifier_sha256", @"resource_identifier_sha256", @"device_id",
    @"inode_id", @"bookmark_sha256", @"classified_at",
    @"root_fingerprint_sha256",
  ];
  return DSHExactKeys(authority, keys) &&
      DSHSchemaVersionIsOne(authority[@"schema_version"]) &&
      [authority[@"workspace_id"] isEqual:record[@"workspace_id"]] &&
      [authority[@"binding_revision"] isEqual:record[@"binding_revision"]] &&
      DSHCanonicalSHA256(authority[@"volume_identifier_sha256"]) &&
      DSHCanonicalSHA256(authority[@"resource_identifier_sha256"]) &&
      DSHCanonicalUnsignedIntegerString(authority[@"device_id"]) &&
      DSHCanonicalUnsignedIntegerString(authority[@"inode_id"]) &&
      [authority[@"bookmark_sha256"] isEqual:bookmark[@"bookmark_sha256"]] &&
      DSHCanonicalTimestamp(authority[@"classified_at"]) &&
      DSHValidGrantedFingerprint(authority, record);
}

static BOOL DSHSameNode(const struct stat &left, const struct stat &right) {
  return left.st_dev == right.st_dev && left.st_ino == right.st_ino &&
         left.st_mode == right.st_mode;
}

static BOOL DSHWorkspaceDescriptorMatchesAuthority(
    int descriptor,
    NSDictionary *authority) {
  if (descriptor < 0 || ![authority isKindOfClass:NSDictionary.class]) {
    return NO;
  }
  struct stat state = {};
  if (fstat(descriptor, &state) != 0 || !S_ISDIR(state.st_mode) ||
      S_ISLNK(state.st_mode)) {
    return NO;
  }
  // st_dev is not durable across reboots (iOS renumbers the data volume), so
  // only the inode is compared against the persisted authority. Callers reach
  // this descriptor by walking down from the app container, which is what a
  // matching device id used to stand for.
  unsigned long long expectedInode = strtoull(
      [authority[@"inode_id"] UTF8String], nullptr, 10);
  return (unsigned long long)state.st_ino == expectedInode;
}

static NSString *DSHUnsignedIntegerString(unsigned long long value) {
  return [NSString stringWithFormat:@"%llu", value];
}

static BOOL DSHWriteAll(int descriptor, const uint8_t *bytes, size_t length) {
  size_t offset = 0;
  while (offset < length) {
    ssize_t written = write(descriptor, bytes + offset, length - offset);
    if (written <= 0) return NO;
    offset += (size_t)written;
  }
  return YES;
}

static BOOL DSHInternalComponent(id value) {
  if (![value isKindOfClass:NSString.class]) return NO;
  NSString *component = value;
  NSData *bytes = [component dataUsingEncoding:NSUTF8StringEncoding
                         allowLossyConversion:NO];
  return bytes.length > 0 && bytes.length <= NAME_MAX &&
         [component rangeOfString:@"/"].location == NSNotFound &&
         [component rangeOfString:@"\\"].location == NSNotFound &&
         [component rangeOfString:@"\0"].location == NSNotFound &&
         [component rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet]
             .location == NSNotFound &&
         ![component isEqual:@"."] && ![component isEqual:@".."];
}

static NSString *DSHFilesystemFoldedComponent(NSString *component) {
  if (![component isKindOfClass:NSString.class]) return nil;
  NSString *normalized = [component precomposedStringWithCanonicalMapping];
  NSString *folded = [normalized
      stringByFoldingWithOptions:NSCaseInsensitiveSearch |
                                 NSDiacriticInsensitiveSearch
                           locale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
  return folded.lowercaseString;
}

static NSString *DSHTruncateDisplayNameForSuffix(NSString *base,
                                                  NSString *suffix) {
  NSUInteger suffixBytes =
      [suffix lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
  if (suffixBytes >= 120) return nil;
  NSUInteger budget = 120 - suffixBytes;
  NSMutableString *prefix = [NSMutableString string];
  NSUInteger index = 0;
  while (index < base.length) {
    NSRange sequence = [base rangeOfComposedCharacterSequenceAtIndex:index];
    NSString *candidate = [base substringWithRange:
        NSMakeRange(0, NSMaxRange(sequence))];
    if ([candidate lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > budget) {
      break;
    }
    [prefix appendString:[base substringWithRange:sequence]];
    index = NSMaxRange(sequence);
  }
  return [prefix stringByAppendingString:suffix];
}

@class DSHLocalWorkspaceAuthorityLock;

@interface DSHLocalWorkspaceAccess ()
@property(nonatomic, strong) NSURL *privateRootURL;
@property(nonatomic, strong) NSURL *documentsRootURL;
@property(nonatomic, copy) DSHLocalWorkspaceClock clock;
@property(nonatomic, copy) DSHLocalWorkspaceUUIDGenerator UUIDGenerator;
@property(nonatomic, copy) DSHLocalWorkspaceLegacyResolver legacyResolver;
@property(nonatomic, copy, nullable) DSHLocalWorkspaceFaultHook faultHook;
@property(nonatomic) BOOL rootIdentityCaptured;
@property(nonatomic) dev_t rootDevice;
@property(nonatomic) ino_t rootInode;
@property(nonatomic) BOOL documentsRootIdentityCaptured;
@property(nonatomic) dev_t documentsRootDevice;
@property(nonatomic) ino_t documentsRootInode;
@property(nonatomic) BOOL bootstrapped;
- (nullable NSDictionary *)verifiedLegacyEvidenceForProjectId:
    (NSString *)projectId;
- (nullable NSDictionary *)migrateLegacyAuthority:(NSDictionary *)authority
                                            record:(NSDictionary *)record;
- (nullable NSDictionary *)terminalValidatedOwnedDescriptorForRecord:
    (NSDictionary *)record
    error:(NSError **)error;
- (nullable DSHLocalWorkspaceAuthorityLock *)acquireAuthorityLock:
    (NSError **)error NS_RETURNS_RETAINED;
- (BOOL)ensurePrivateLayoutLocked:(NSError **)error;
- (nullable NSDictionary *)loadRegistry:(NSError **)error
                                  digest:(NSString *_Nullable *_Nullable)digest;
- (nullable NSDictionary *)recordInRegistry:(NSDictionary *)registry
                                  workspaceId:(NSString *)workspaceId;
- (nullable NSDictionary *)loadAuthorityForRecord:(NSDictionary *)record
                                             error:(NSError **)error;
- (nullable NSSet<NSString *> *)verifiedLegacyCapabilitiesForRecord:
    (NSDictionary *)record
    authority:(NSDictionary *)authority;
- (int)openOwnedRootDescriptorForRecord:(NSDictionary *)record
                               authority:(NSDictionary *)authority
                                  error:(NSError **)error;
- (NSString *)metadataStatusForRecord:(NSDictionary *)record
                              authority:(NSDictionary *)authority;
@end

@interface DSHLocalWorkspaceAuthorityMutationGuard ()
@property(nonatomic) int descriptor;
@property(nonatomic, weak) DSHLocalWorkspaceAccess *owner;
@end

@implementation DSHLocalWorkspaceAuthorityMutationGuard
- (instancetype)init {
  self = [super init];
  if (self) _descriptor = -1;
  return self;
}
- (void)dealloc {
  if (_descriptor >= 0) {
    (void)flock(_descriptor, LOCK_UN);
    close(_descriptor);
  }
}
@end

@interface DSHLocalWorkspaceAuthorityLock :
    DSHLocalWorkspaceAuthorityMutationGuard
@end

@implementation DSHLocalWorkspaceAuthorityLock
@end

@interface DSHLocalWorkspaceLease ()
/// Immutable operation-lifetime guard. It carries the verified private
/// authority snapshot without retaining the registry's flock across async
/// consumers; every new native open still revalidates the registry/authority.
@property(nonatomic, copy) NSDictionary *authorityGuard;
@property(nonatomic, readwrite, copy) NSString *workspaceId;
@property(nonatomic, readwrite) NSUInteger bindingRevision;
@property(nonatomic, readwrite) int rootDescriptor;
@property(nonatomic, readwrite) BOOL supportsGit;
@property(nonatomic, readwrite) BOOL supportsProjectContext;
- (instancetype)initWithWorkspaceId:(NSString *)workspaceId
                   bindingRevision:(NSUInteger)bindingRevision
                    rootDescriptor:(int)rootDescriptor
                        supportsGit:(BOOL)supportsGit
              supportsProjectContext:(BOOL)supportsProjectContext
                      authorityGuard:(NSDictionary *)authorityGuard;
@end

@implementation DSHLocalWorkspaceLease

- (instancetype)initWithWorkspaceId:(NSString *)workspaceId
                   bindingRevision:(NSUInteger)bindingRevision
                    rootDescriptor:(int)rootDescriptor
                        supportsGit:(BOOL)supportsGit
              supportsProjectContext:(BOOL)supportsProjectContext
                      authorityGuard:(NSDictionary *)authorityGuard {
  self = [super init];
  if (self != nil) {
    _workspaceId = [workspaceId copy];
    _bindingRevision = bindingRevision;
    _rootDescriptor = rootDescriptor;
    _supportsGit = supportsGit;
    _supportsProjectContext = supportsProjectContext;
    _authorityGuard = [authorityGuard copy];
  }
  return self;
}

- (void)dealloc {
  if (_rootDescriptor >= 0) {
    close(_rootDescriptor);
    _rootDescriptor = -1;
  }
}

@end

@implementation DSHLocalWorkspaceAccess

- (instancetype)initWithPrivateRootURL:(NSURL *)privateRootURL
                                  clock:(DSHLocalWorkspaceClock)clock
                          UUIDGenerator:(DSHLocalWorkspaceUUIDGenerator)UUIDGenerator
                         legacyResolver:(DSHLocalWorkspaceLegacyResolver)legacyResolver
                              faultHook:(DSHLocalWorkspaceFaultHook)faultHook {
  return [self initWithPrivateRootURL:privateRootURL
                    documentsRootURL:nil
                                 clock:clock
                         UUIDGenerator:UUIDGenerator
                        legacyResolver:legacyResolver
                             faultHook:faultHook];
}

- (instancetype)initWithPrivateRootURL:(NSURL *)privateRootURL
                     documentsRootURL:(NSURL *)documentsRootURL
                                  clock:(DSHLocalWorkspaceClock)clock
                         UUIDGenerator:(DSHLocalWorkspaceUUIDGenerator)UUIDGenerator
                         legacyResolver:(DSHLocalWorkspaceLegacyResolver)legacyResolver
                              faultHook:(DSHLocalWorkspaceFaultHook)faultHook {
  self = [super init];
  if (self) {
    _privateRootURL = [privateRootURL copy];
    _documentsRootURL = [documentsRootURL copy];
    _clock = [clock copy];
    _UUIDGenerator = [UUIDGenerator copy];
    _legacyResolver = [legacyResolver copy];
    _faultHook = [faultHook copy];
  }
  return self;
}

- (nullable NSDictionary *)verifiedLegacyEvidenceForProjectId:
    (NSString *)projectId {
  if (!DSHCanonicalUUID(projectId)) return nil;
  NSDictionary *evidence = nil;
  NSError *resolverError = nil;
  @try {
    if (!self.legacyResolver(projectId, &evidence, &resolverError) ||
        !DSHValidLegacyEvidence(evidence, projectId)) {
      return nil;
    }
  } @catch (__unused NSException *exception) {
    return nil;
  }
  return [evidence copy];
}

- (nullable NSDictionary *)migrateLegacyAuthority:(NSDictionary *)authority
                                            record:(NSDictionary *)record {
  NSString *projectId = authority[@"legacy_project_id"];
  NSString *projectMetadata = authority[@"root_identity_sha256"];
  NSDictionary *evidence = [self verifiedLegacyEvidenceForProjectId:projectId];
  if (evidence == nil ||
      ![evidence[@"metadata_sha256"] isEqual:projectMetadata]) return nil;
  NSMutableDictionary *physical = [evidence mutableCopy];
  physical[@"project_metadata_sha256"] = evidence[@"metadata_sha256"];
  [physical removeObjectsForKeys:@[
    @"project_id", @"display_name", @"metadata_sha256", @"capabilities"
  ]];
  NSMutableDictionary *migrated =
      [DSHMigrateLegacyAuthority(authority, record, physical) mutableCopy];
  if (migrated == nil) return nil;
  NSMutableArray *orderedCapabilities = [NSMutableArray array];
  for (NSString *capability in DSHCapabilityOrder()) {
    if ([evidence[@"capabilities"] containsObject:capability]) {
      [orderedCapabilities addObject:capability];
    }
  }
  migrated[@"capabilities"] = orderedCapabilities;
  return migrated;
}

- (NSURL *)workspaceStoreURL {
  return [self.privateRootURL URLByAppendingPathComponent:@"local-workspaces"
                                              isDirectory:YES];
}

- (NSURL *)bindingsStoreURL {
  return [self.privateRootURL URLByAppendingPathComponent:@"workspace-bindings"
                                              isDirectory:YES];
}

- (NSURL *)registryURL {
  return [[self workspaceStoreURL] URLByAppendingPathComponent:@"registry-v1.json"];
}

- (NSURL *)receiptsURL {
  return [[self workspaceStoreURL] URLByAppendingPathComponent:@"receipts-v1.json"];
}

- (NSURL *)journalURL {
  return [[self workspaceStoreURL]
      URLByAppendingPathComponent:@"authority-journal-v1.json"];
}

- (NSURL *)layoutManifestURL {
  return [[self workspaceStoreURL]
      URLByAppendingPathComponent:@"layout-v1.json"];
}

- (NSURL *)authorityLockURL {
  return [[self workspaceStoreURL]
      URLByAppendingPathComponent:@"authority.lock"];
}

- (nullable NSURL *)resolvedDocumentsRootURL {
  if (self.documentsRootURL != nil) return self.documentsRootURL;
  NSArray<NSString *> *directories =
      NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                          NSUserDomainMask, YES);
  NSString *path = directories.firstObject;
  return path.length == 0 ? nil : [NSURL fileURLWithPath:path isDirectory:YES];
}

- (nullable NSURL *)ownedWorkspacesRootURL {
  NSURL *documents = [self resolvedDocumentsRootURL];
  return documents == nil
      ? nil
      : [documents URLByAppendingPathComponent:@"Rish Workspaces"
                                    isDirectory:YES];
}

- (BOOL)fsyncDirectoryURL:(NSURL *)url
                     stage:(nullable NSString *)stage
                     error:(NSError **)error {
  if (url == nil) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
    return NO;
  }
  int descriptor = open(url.fileSystemRepresentation,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (descriptor < 0 || fsync(descriptor) != 0) {
    if (descriptor >= 0) close(descriptor);
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  close(descriptor);
  if (stage != nil && self.faultHook != nil && self.faultHook(stage)) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  return YES;
}

- (BOOL)captureDocumentsRootIdentity:(NSError **)error {
  NSURL *documents = [self resolvedDocumentsRootURL];
  if (documents == nil || !documents.isFileURL ||
      ![documents.path hasPrefix:@"/"]) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
    return NO;
  }
  struct stat state = {};
  if (lstat(documents.fileSystemRepresentation, &state) != 0 ||
      !S_ISDIR(state.st_mode) || S_ISLNK(state.st_mode)) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
    return NO;
  }
  if (!self.documentsRootIdentityCaptured) {
    self.documentsRootIdentityCaptured = YES;
    self.documentsRootDevice = state.st_dev;
    self.documentsRootInode = state.st_ino;
    return YES;
  }
  if (state.st_dev != self.documentsRootDevice ||
      state.st_ino != self.documentsRootInode) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
    return NO;
  }
  return YES;
}

- (BOOL)ensureOwnedDocumentsLayout:(NSError **)error {
  NSURL *documents = [self resolvedDocumentsRootURL];
  if (documents == nil || !documents.isFileURL ||
      ![documents.path hasPrefix:@"/"]) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
    return NO;
  }
  struct stat state = {};
  if (lstat(documents.fileSystemRepresentation, &state) != 0) {
    if (errno != ENOENT ||
        ![NSFileManager.defaultManager
            createDirectoryAtURL:documents
       withIntermediateDirectories:YES
                        attributes:@{NSFilePosixPermissions : @0700}
                             error:nil]) {
      DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
      return NO;
    }
  }
  if (![self captureDocumentsRootIdentity:error]) return NO;
  NSURL *container = [self ownedWorkspacesRootURL];
  if (container == nil) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
    return NO;
  }
  if (lstat(container.fileSystemRepresentation, &state) != 0) {
    if (errno != ENOENT || mkdir(container.fileSystemRepresentation, 0700) != 0) {
      DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
      return NO;
    }
    if (![self fsyncDirectoryURL:documents stage:nil error:error]) return NO;
  }
  if (lstat(container.fileSystemRepresentation, &state) != 0 ||
      !S_ISDIR(state.st_mode) || S_ISLNK(state.st_mode) ||
      chmod(container.fileSystemRepresentation, 0700) != 0) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  // User-visible Documents content must not be blanket backup-excluded. On
  // filesystems that do not expose the NSURL resource value, the operation is
  // best-effort and the absence of a private exclusion is still safe.
  [container setResourceValue:@NO forKey:NSURLIsExcludedFromBackupKey error:nil];
  [documents setResourceValue:@NO forKey:NSURLIsExcludedFromBackupKey error:nil];
  return YES;
}

- (nullable NSString *)allocateOwnedDirectoryNameForDisplayName:
    (NSString *)displayName
                                          registry:(NSDictionary *)registry
                                             error:(NSError **)error {
  if (!DSHCanonicalDisplayName(displayName)) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorInvalid);
    return nil;
  }
  NSMutableSet<NSString *> *occupied = [NSMutableSet set];
  for (NSDictionary *record in registry[@"records"]) {
    NSString *name = record[@"owned_directory_name"];
    if (![name isEqual:NSNull.null]) {
      NSString *folded = DSHFilesystemFoldedComponent(name);
      if (folded != nil) [occupied addObject:folded];
    }
  }
  NSArray<NSURL *> *entries = [NSFileManager.defaultManager
      contentsOfDirectoryAtURL:[self ownedWorkspacesRootURL]
       includingPropertiesForKeys:nil
                          options:0
                            error:nil];
  if (entries == nil) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return nil;
  }
  for (NSURL *entry in entries) {
    NSString *folded = DSHFilesystemFoldedComponent(entry.lastPathComponent);
    if (folded != nil) [occupied addObject:folded];
  }
  NSString *candidate = displayName;
  NSUInteger ordinal = 0;
  while ([occupied containsObject:DSHFilesystemFoldedComponent(candidate)]) {
    ordinal += 1;
    NSString *suffix = [NSString stringWithFormat:@" (%lu)",
                                                  (unsigned long)ordinal];
    candidate = DSHTruncateDisplayNameForSuffix(displayName, suffix);
    if (candidate == nil || !DSHInternalComponent(candidate)) {
      DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorInvalid);
      return nil;
    }
  }
  return candidate;
}

- (BOOL)ownedRootIdentityForDirectoryName:(NSString *)directoryName
                                  device:(dev_t *)deviceOut
                                   inode:(ino_t *)inodeOut
                                   error:(NSError **)error {
  NSURL *root = [[self ownedWorkspacesRootURL]
      URLByAppendingPathComponent:directoryName isDirectory:YES];
  struct stat state = {};
  if (!DSHInternalComponent(directoryName) ||
      lstat(root.fileSystemRepresentation, &state) != 0 ||
      !S_ISDIR(state.st_mode) || S_ISLNK(state.st_mode) ||
      state.st_nlink < 2) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
    return NO;
  }
  if (deviceOut != nil) *deviceOut = state.st_dev;
  if (inodeOut != nil) *inodeOut = state.st_ino;
  return YES;
}

- (BOOL)validateOwnedRootForRecord:(NSDictionary *)record
                          authority:(NSDictionary *)authority
                              error:(NSError **)error {
  if (![record[@"root_locator_kind"] isEqual:@"documents_owned"] ||
      !DSHValidOwnedAuthority(authority, record)) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  dev_t device = 0;
  ino_t inode = 0;
  NSError *identityError = nil;
  if (![self ownedRootIdentityForDirectoryName:record[@"owned_directory_name"]
                                         device:&device
                                          inode:&inode
                                          error:&identityError]) {
    NSURL *root = [[self ownedWorkspacesRootURL]
        URLByAppendingPathComponent:record[@"owned_directory_name"]
                         isDirectory:YES];
    struct stat replacedState = {};
    if (lstat(root.fileSystemRepresentation, &replacedState) == 0) {
      DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorRootChanged);
    } else if (error != nil) {
      *error = identityError ?: DSHWorkspaceError(
          DSHLocalWorkspaceAccessErrorUnavailable);
    }
    return NO;
  }
  unsigned long long expectedInode =
      strtoull([authority[@"inode_id"] UTF8String], NULL, 10);
  if ((unsigned long long)inode != expectedInode) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorRootChanged);
    return NO;
  }
  // A persisted st_dev is not durable: iOS renumbers the data volume across
  // reboots, so a stored device id that no longer matches says nothing about
  // the directory. Prove containment against the live owned-workspaces root
  // instead, which is the property the device id was standing in for: the
  // workspace directory must sit on the same volume as this app's container.
  struct stat ownedRootState = {};
  if (lstat(self.ownedWorkspacesRootURL.fileSystemRepresentation,
            &ownedRootState) != 0 ||
      !S_ISDIR(ownedRootState.st_mode) || S_ISLNK(ownedRootState.st_mode)) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
    return NO;
  }
  if (device != ownedRootState.st_dev) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorRootChanged);
    return NO;
  }
  return YES;
}

- (NSURL *)authorityURLForKind:(NSString *)kind
                    workspaceId:(NSString *)workspaceId
                       revision:(NSNumber *)revision {
  NSString *name = [NSString stringWithFormat:@"%@-%@-r%@.json", kind,
                    workspaceId, revision];
  return [[self bindingsStoreURL] URLByAppendingPathComponent:name];
}

- (BOOL)validateRootIdentity:(NSError **)error {
  if (![self.privateRootURL isFileURL] ||
      ![self.privateRootURL.path hasPrefix:@"/"]) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
    return NO;
  }
  struct stat state = {};
  if (lstat(self.privateRootURL.fileSystemRepresentation, &state) != 0 ||
      !S_ISDIR(state.st_mode) || S_ISLNK(state.st_mode)) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
    return NO;
  }
  if (!self.rootIdentityCaptured) {
    self.rootIdentityCaptured = YES;
    self.rootDevice = state.st_dev;
    self.rootInode = state.st_ino;
    return YES;
  }
  if (state.st_dev != self.rootDevice || state.st_ino != self.rootInode) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
    return NO;
  }
  return YES;
}

- (BOOL)secureDirectoryAtURL:(NSURL *)url error:(NSError **)error {
  struct stat state = {};
  if (lstat(url.fileSystemRepresentation, &state) != 0) {
    if (errno != ENOENT || mkdir(url.fileSystemRepresentation, 0700) != 0) {
      DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
      return NO;
    }
    int parent = open(url.URLByDeletingLastPathComponent.fileSystemRepresentation,
                      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (parent < 0 || fsync(parent) != 0) {
      if (parent >= 0) close(parent);
      DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
      return NO;
    }
    close(parent);
    if (lstat(url.fileSystemRepresentation, &state) != 0) {
      DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
      return NO;
    }
  }
  if (!S_ISDIR(state.st_mode) || S_ISLNK(state.st_mode) ||
      chmod(url.fileSystemRepresentation, 0700) != 0 ||
      ![NSFileManager.defaultManager
          setAttributes:@{NSFileProtectionKey : DSHWorkspaceStoreProtectionClass()}
           ofItemAtPath:url.path error:nil] ||
      ![url setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil]) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  return YES;
}

- (nullable DSHLocalWorkspaceAuthorityLock *)acquireAuthorityLock:
    (NSError **)error {
  if (![self validateRootIdentity:error] ||
      ![self secureDirectoryAtURL:self.workspaceStoreURL error:error] ||
      ![self secureDirectoryAtURL:self.bindingsStoreURL error:error]) {
    return nil;
  }
  NSURL *url = self.authorityLockURL;
  BOOL created = YES;
  int descriptor = open(url.fileSystemRepresentation,
                        O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                        0600);
  if (descriptor < 0 && errno == EEXIST) {
    created = NO;
    descriptor = open(url.fileSystemRepresentation,
                      O_RDWR | O_CLOEXEC | O_NOFOLLOW);
  }
  struct stat before = {};
  if (descriptor < 0 || fstat(descriptor, &before) != 0 ||
      !S_ISREG(before.st_mode) || before.st_nlink != 1 ||
      (before.st_mode & 0777) != 0600) {
    if (descriptor >= 0) close(descriptor);
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return nil;
  }
  if (created) {
    if (![NSFileManager.defaultManager
            setAttributes:@{NSFilePosixPermissions : @0600,
                            NSFileProtectionKey :
                                DSHWorkspaceStoreProtectionClass()}
             ofItemAtPath:url.path error:nil] ||
        ![url setResourceValue:@YES
                        forKey:NSURLIsExcludedFromBackupKey error:nil]) {
      close(descriptor);
      DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
      return nil;
    }
    int parent = open(url.URLByDeletingLastPathComponent.fileSystemRepresentation,
                      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    BOOL durable = fsync(descriptor) == 0 && parent >= 0 && fsync(parent) == 0;
    if (parent >= 0) close(parent);
    if (!durable) {
      close(descriptor);
      DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
      return nil;
    }
  } else {
    NSNumber *excluded = nil;
    BOOL protectionValid = DSHWorkspaceStoreProtectionValidAtURL(url);
    if (!protectionValid ||
        ![url getResourceValue:&excluded
                        forKey:NSURLIsExcludedFromBackupKey error:nil] ||
        !excluded.boolValue) {
      close(descriptor);
      DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
      return nil;
    }
  }
  if (flock(descriptor, LOCK_EX) != 0 || ![self validateRootIdentity:error]) {
    close(descriptor);
    if (error != nil && *error == nil) {
      DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    }
    return nil;
  }
  struct stat after = {};
  struct stat visible = {};
  if (fstat(descriptor, &after) != 0 ||
      lstat(url.fileSystemRepresentation, &visible) != 0 ||
      !DSHSameNode(before, after) || !DSHSameNode(after, visible)) {
    (void)flock(descriptor, LOCK_UN);
    close(descriptor);
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return nil;
  }
  DSHLocalWorkspaceAuthorityLock *token =
      [[DSHLocalWorkspaceAuthorityLock alloc] init];
  token.descriptor = descriptor;
  token.owner = self;
  return token;
}

- (DSHLocalWorkspaceAuthorityMutationGuard *)
    acquireAuthorityMutationGuard:(NSError **)error {
  return [self acquireAuthorityLock:error];
}

- (BOOL)validateWorkspaceForClearanceId:(NSString *)workspaceId
                        bindingRevision:(NSUInteger)revision
                 authorityMutationGuard:
                     (DSHLocalWorkspaceAuthorityMutationGuard *)guard
                                   error:(NSError **)error {
  if (guard == nil || guard.owner != self || guard.descriptor < 0 ||
      !DSHCanonicalUUID(workspaceId) || revision == 0 ||
      revision > DSHWorkspaceMaxSafeInteger) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorInvalid);
    return NO;
  }
  if (![self ensurePrivateLayoutLocked:error]) return NO;
  NSDictionary *registry = [self loadRegistry:error digest:nil];
  NSDictionary *record = registry == nil ? nil :
      [self recordInRegistry:registry workspaceId:workspaceId];
  if (record == nil ||
      ![record[@"binding_revision"] isEqual:@(revision)]) {
    DSHSetWorkspaceError(error, record == nil
        ? DSHLocalWorkspaceAccessErrorNotFound
        : DSHLocalWorkspaceAccessErrorRevisionStale);
    return NO;
  }
  NSString *locator = record[@"root_locator_kind"];
  NSString *origin = record[@"origin"];
  if ([locator isEqual:@"legacy_app_owned"]) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorConflict);
    return NO;
  }
  BOOL originValid =
      ([locator isEqual:@"documents_owned"] &&
       ([origin isEqual:@"rish_created"] || [origin isEqual:@"imported"])) ||
      ([locator isEqual:@"security_scoped"] &&
       [origin isEqual:@"granted_folder"]);
  NSDictionary *authority = originValid
      ? [self loadAuthorityForRecord:record error:error] : nil;
  if (!originValid || authority == nil ||
      ![[self metadataStatusForRecord:record authority:authority]
          isEqual:@"ok"]) {
    if (error != nil && *error == nil) {
      DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorConflict);
    }
    return NO;
  }
  return YES;
}

- (BOOL)writeProtectedData:(NSData *)data
                     toURL:(NSURL *)url
                     error:(NSError **)error {
  if (![data isKindOfClass:NSData.class]) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  NSString *temporaryName = [NSString stringWithFormat:@".%@.%@.tmp",
      url.lastPathComponent, NSUUID.UUID.UUIDString.lowercaseString];
  NSURL *temporary = [url.URLByDeletingLastPathComponent
      URLByAppendingPathComponent:temporaryName];
  int descriptor = open(temporary.fileSystemRepresentation,
                        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                        0600);
  if (descriptor < 0 ||
      !DSHWriteAll(descriptor, (const uint8_t *)data.bytes, data.length) ||
      fsync(descriptor) != 0 || close(descriptor) != 0) {
    if (descriptor >= 0) close(descriptor);
    unlink(temporary.fileSystemRepresentation);
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  if (![NSFileManager.defaultManager
          setAttributes:@{NSFilePosixPermissions : @0600,
                          NSFileProtectionKey :
                              DSHWorkspaceStoreProtectionClass()}
           ofItemAtPath:temporary.path error:nil] ||
      ![temporary setResourceValue:@YES
                            forKey:NSURLIsExcludedFromBackupKey
                             error:nil] ||
      rename(temporary.fileSystemRepresentation, url.fileSystemRepresentation) !=
          0 ||
      ![NSFileManager.defaultManager
          setAttributes:@{NSFilePosixPermissions : @0600,
                          NSFileProtectionKey :
                              DSHWorkspaceStoreProtectionClass()}
           ofItemAtPath:url.path error:nil] ||
      ![url setResourceValue:@YES
                      forKey:NSURLIsExcludedFromBackupKey
                       error:nil]) {
    unlink(temporary.fileSystemRepresentation);
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  int parent = open(url.URLByDeletingLastPathComponent.fileSystemRepresentation,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  BOOL durable = parent >= 0 && fsync(parent) == 0;
  if (parent >= 0) close(parent);
  if (!durable) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  return YES;
}

- (BOOL)writeProtectedObject:(id)object
                       toURL:(NSURL *)url
                    maxBytes:(NSUInteger)maxBytes
                       error:(NSError **)error {
  NSData *data = DSHCanonicalJSON(object);
  if (data == nil || data.length > maxBytes) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  return [self writeProtectedData:data toURL:url error:error];
}

- (nullable NSData *)readProtectedURL:(NSURL *)url
                              maxBytes:(NSUInteger)maxBytes
                                 error:(NSError **)error {
  struct stat before = {};
  if (lstat(url.fileSystemRepresentation, &before) != 0 ||
      !S_ISREG(before.st_mode) || S_ISLNK(before.st_mode) ||
      before.st_nlink != 1 || (before.st_mode & 0777) != 0600 ||
      before.st_size < 0 || (unsigned long long)before.st_size > maxBytes) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return nil;
  }
  NSNumber *excluded = nil;
  BOOL protectionValid = DSHWorkspaceStoreProtectionValidAtURL(url);
  if (!protectionValid ||
      ![url getResourceValue:&excluded
                      forKey:NSURLIsExcludedFromBackupKey error:nil] ||
      !excluded.boolValue) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return nil;
  }
  int descriptor = open(url.fileSystemRepresentation,
                        O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  struct stat opened = {};
  if (descriptor < 0 || fstat(descriptor, &opened) != 0 ||
      !DSHSameNode(before, opened)) {
    if (descriptor >= 0) close(descriptor);
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return nil;
  }
  NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)before.st_size];
  size_t offset = 0;
  while (offset < data.length) {
    ssize_t count = pread(descriptor,
                          (uint8_t *)data.mutableBytes + offset,
                          data.length - offset, (off_t)offset);
    if (count <= 0) break;
    offset += (size_t)count;
  }
  struct stat after = {};
  BOOL valid = offset == data.length && fstat(descriptor, &after) == 0 &&
               DSHSameNode(opened, after) && opened.st_size == after.st_size &&
               opened.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec &&
               opened.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec;
  close(descriptor);
  if (!valid) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return nil;
  }
  return [data copy];
}

- (nullable NSDictionary *)readProtectedObjectAtURL:(NSURL *)url
                                            maxBytes:(NSUInteger)maxBytes
                                               error:(NSError **)error {
  NSData *data = [self readProtectedURL:url maxBytes:maxBytes error:error];
  if (data == nil) return nil;
  if (!DSHJSONHasBoundedExactStructure(data)) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return nil;
  }
  id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![object isKindOfClass:NSDictionary.class]) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return nil;
  }
  return object;
}

- (BOOL)removeProtectedURL:(NSURL *)url error:(NSError **)error {
  if (unlink(url.fileSystemRepresentation) != 0 && errno != ENOENT) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  int parent = open(url.URLByDeletingLastPathComponent.fileSystemRepresentation,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  BOOL durable = parent >= 0 && fsync(parent) == 0;
  if (parent >= 0) close(parent);
  if (!durable) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  return YES;
}

- (nullable NSDictionary *)loadRegistry:(NSError **)error
                                  digest:(NSString **)digest {
  NSData *data = [self readProtectedURL:self.registryURL
                               maxBytes:DSHWorkspaceRegistryMaxBytes
                                  error:error];
  if (data == nil) return nil;
  if (!DSHJSONHasBoundedExactStructure(data)) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return nil;
  }
  id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![parsed isKindOfClass:NSDictionary.class] ||
      !DSHExactKeys(parsed, @[@"schema_version", @"generation", @"records"]) ||
      !DSHSchemaVersionIsOne(parsed[@"schema_version"]) ||
      !DSHIsSafeInteger(parsed[@"generation"], YES) ||
      ![parsed[@"records"] isKindOfClass:NSArray.class] ||
      [parsed[@"records"] count] > DSHWorkspaceRegistryMaxRecords) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return nil;
  }
  NSMutableSet *workspaceIds = [NSMutableSet set];
  NSMutableSet *directoryNames = [NSMutableSet set];
  NSString *previous = nil;
  for (id record in parsed[@"records"]) {
    if (![record isKindOfClass:NSDictionary.class] ||
        !DSHValidWorkspaceRecord(record)) {
      DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
      return nil;
    }
    NSString *workspaceId = record[@"workspace_id"];
    if ((previous != nil && [previous compare:workspaceId] != NSOrderedAscending) ||
        [workspaceIds containsObject:workspaceId]) {
      DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
      return nil;
    }
    [workspaceIds addObject:workspaceId];
    previous = workspaceId;
    if (record[@"owned_directory_name"] != NSNull.null) {
      NSString *folded = [record[@"owned_directory_name"]
          stringByFoldingWithOptions:NSCaseInsensitiveSearch |
                                     NSDiacriticInsensitiveSearch
                              locale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
      folded = [folded precomposedStringWithCanonicalMapping];
      if ([directoryNames containsObject:folded]) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        return nil;
      }
      [directoryNames addObject:folded];
    }
  }
  if (digest != nil) *digest = DSHSHA256(data);
  return parsed;
}

- (nullable NSDictionary *)loadAuthorityForRecord:(NSDictionary *)record
                                              error:(NSError **)error {
  NSString *locator = record[@"root_locator_kind"];
  NSString *workspaceId = record[@"workspace_id"];
  NSNumber *revision = record[@"binding_revision"];
  if ([locator isEqual:@"documents_owned"]) {
    NSURL *ownedURL = [self authorityURLForKind:@"owned" workspaceId:workspaceId
                                         revision:revision];
    NSDictionary *owned = [self readProtectedObjectAtURL:
        ownedURL
                                               maxBytes:DSHWorkspaceAuthorityMaxBytes
                                                  error:error];
    if (owned != nil && !DSHValidOwnedAuthority(owned, record)) {
      NSDictionary *migrated = DSHMigrateOwnedAuthority(owned, record);
      if (migrated != nil) {
        if (![self writeProtectedObject:migrated
                                  toURL:ownedURL
                               maxBytes:DSHWorkspaceAuthorityMaxBytes
                                  error:error]) {
          return nil;
        }
        owned = migrated;
      }
    }
    if (owned == nil || !DSHValidOwnedAuthority(owned, record)) {
      if (owned != nil) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
      }
      return nil;
    }
    return owned;
  }
  if ([locator isEqual:@"security_scoped"]) {
    NSURL *bookmarkURL = [self authorityURLForKind:@"bookmark"
                                        workspaceId:workspaceId
                                           revision:revision];
    NSDictionary *bookmark = [self readProtectedObjectAtURL:bookmarkURL
                                                  maxBytes:DSHWorkspaceAuthorityMaxBytes
                                                     error:error];
    if (bookmark == nil || !DSHValidBookmarkAuthority(bookmark, record)) {
      if (bookmark != nil) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
      }
      return nil;
    }
    NSURL *grantedURL = [self authorityURLForKind:@"granted"
                                       workspaceId:workspaceId
                                          revision:revision];
    NSDictionary *granted = [self readProtectedObjectAtURL:grantedURL
                                                 maxBytes:DSHWorkspaceAuthorityMaxBytes
                                                    error:error];
    if (granted != nil && !DSHValidGrantedAuthority(granted, record, bookmark)) {
      NSDictionary *migrated = DSHMigrateGrantedAuthority(granted, record,
                                                          bookmark);
      if (migrated != nil) {
        if (![self writeProtectedObject:migrated
                                  toURL:grantedURL
                               maxBytes:DSHWorkspaceAuthorityMaxBytes
                                  error:error]) {
          return nil;
        }
        granted = migrated;
      }
    }
    if (granted == nil ||
        !DSHValidGrantedAuthority(granted, record, bookmark)) {
      if (granted != nil) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
      }
      return nil;
    }
    return @{ @"bookmark" : bookmark, @"granted" : granted };
  }
  if ([locator isEqual:@"legacy_app_owned"]) {
    NSURL *legacyURL = [self authorityURLForKind:@"legacy" workspaceId:workspaceId
                                        revision:revision];
    NSDictionary *legacy = [self readProtectedObjectAtURL:legacyURL
                                                maxBytes:DSHWorkspaceAuthorityMaxBytes
                                                   error:error];
    if (legacy != nil && !DSHValidLegacyAuthority(legacy, record)) {
      NSDictionary *migrated = [self migrateLegacyAuthority:legacy
                                                     record:record];
      if (migrated != nil) {
        if (![self writeProtectedObject:migrated
                                  toURL:legacyURL
                               maxBytes:DSHWorkspaceAuthorityMaxBytes
                                  error:error]) {
          return nil;
        }
        legacy = migrated;
      }
    }
    if (legacy == nil || !DSHValidLegacyAuthority(legacy, record)) {
      if (legacy != nil) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
      }
      return nil;
    }
    return legacy;
  }
  DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
  return nil;
}

- (NSDictionary *)zeroCapabilitiesForRecord:(NSDictionary *)record {
  BOOL filesVisible = [record[@"root_locator_kind"] isEqual:@"documents_owned"];
  return @{
    @"read" : @NO,
    @"write" : @NO,
    @"git" : @NO,
    @"project_context" : @NO,
    @"files_visible" : @(filesVisible),
  };
}

- (NSDictionary *)descriptorForRecord:(NSDictionary *)record
                                status:(NSString *)status
                          capabilities:(nullable NSSet<NSString *> *)capabilities {
  return DSHWorkspaceGrantsReduce(@"descriptor", @{
    @"record" : record ?: NSNull.null,
    @"status" : status ?: NSNull.null,
    @"grants" : (capabilities ?: [NSSet set]).allObjects,
  })[@"descriptor"];
}

- (NSSet<NSString *> *)operationalCapabilitiesForMetadataRecord:(NSDictionary *)record
                                                        authority:(NSDictionary *)authority
                                                           status:(NSString *)status {
  // A legacy root's grants depend on re-reading its project metadata and
  // comparing physical identity, which only this side can do; the answer is
  // handed across rather than guessed at.
  NSSet *legacy = [record[@"root_locator_kind"] isEqual:@"legacy_app_owned"]
      ? [self verifiedLegacyCapabilitiesForRecord:record authority:authority]
      : nil;
  NSMutableDictionary *request = [@{
    @"locator_kind" : record[@"root_locator_kind"] ?: NSNull.null,
    @"status" : status ?: NSNull.null,
  } mutableCopy];
  if (legacy != nil) request[@"verified_legacy"] = legacy.allObjects;
  id grants = DSHWorkspaceGrantsReduce(@"operational_grants", request)[@"grants"];
  return [grants isKindOfClass:NSArray.class] ? [NSSet setWithArray:grants]
                                              : [NSSet set];
}

- (nullable NSSet<NSString *> *)verifiedLegacyCapabilitiesForRecord:
    (NSDictionary *)record
    authority:(NSDictionary *)authority {
  if (![record[@"root_locator_kind"] isEqual:@"legacy_app_owned"] ||
      !DSHValidLegacyAuthority(authority, record)) {
    return nil;
  }
  @try {
    NSDictionary *evidence =
        [self verifiedLegacyEvidenceForProjectId:record[@"legacy_project_id"]];
    if (evidence != nil &&
        [evidence[@"display_name"] isEqual:record[@"display_name"]] &&
        [evidence[@"metadata_sha256"]
            isEqual:authority[@"root_identity_sha256"]] &&
        [evidence[@"capabilities"]
            isEqual:[NSSet setWithArray:authority[@"capabilities"]]] &&
        DSHLegacyPhysicalIdentityMatchesAuthority(evidence, authority)) {
      return evidence[@"capabilities"];
    }
  } @catch (__unused NSException *exception) {
  }
  return nil;
}

- (NSString *)metadataStatusForRecord:(NSDictionary *)record
                              authority:(NSDictionary *)authority {
  if ([record[@"root_locator_kind"] isEqual:@"documents_owned"]) {
    if ((![record[@"origin"] isEqual:@"rish_created"] &&
         ![record[@"origin"] isEqual:@"imported"]) ||
        ![self captureDocumentsRootIdentity:nil] ||
        ![self validateOwnedRootForRecord:record authority:authority error:nil]) {
      return @"unavailable";
    }
    return @"ok";
  }
  if ([record[@"root_locator_kind"] isEqual:@"security_scoped"]) {
    NSDictionary *bookmarkAuthority = authority[@"bookmark"];
    NSDictionary *grantedAuthority = authority[@"granted"];
    NSData *bookmark = [[NSData alloc]
        initWithBase64EncodedString:bookmarkAuthority[@"bookmark_bytes_base64"]
                            options:0];
    if (bookmark == nil || bookmark.length > DSHWorkspaceBookmarkMaxBytes) {
      return @"revoked";
    }
    BOOL bookmarkStale = NO;
    NSError *resolutionError = nil;
    NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark
                                           options:
#if TARGET_OS_OSX || TARGET_OS_MACCATALYST
                                               NSURLBookmarkResolutionWithSecurityScope
#else
                                               0
#endif
                                     relativeToURL:nil
                               bookmarkDataIsStale:&bookmarkStale
                                             error:&resolutionError];
    if (url == nil) return bookmarkStale ? @"stale" : @"revoked";
    BOOL scopeStarted = NO;
    @try {
      if (bookmarkStale) return @"stale";
      scopeStarted = [url startAccessingSecurityScopedResource];
      if (!scopeStarted) return @"revoked";
      struct stat state = {};
      BOOL isDirectory = lstat(url.fileSystemRepresentation, &state) == 0 &&
                         S_ISDIR(state.st_mode) && !S_ISLNK(state.st_mode);
      // The security-scoped bookmark plus the persisted inode identify this
      // folder. A persisted st_dev does not survive a reboot, so comparing it
      // would report every granted folder as revoked after a restart.
      unsigned long long expectedInode = strtoull(
          [grantedAuthority[@"inode_id"] UTF8String], nullptr, 10);
      BOOL identityMatches = isDirectory &&
          (unsigned long long)state.st_ino == expectedInode;
      NSNumber *ubiquitous = nil;
      NSString *downloadStatus = nil;
      [url getResourceValue:&ubiquitous
                     forKey:NSURLIsUbiquitousItemKey
                      error:nil];
      [url getResourceValue:&downloadStatus
                     forKey:NSURLUbiquitousItemDownloadingStatusKey
                      error:nil];
      if (!identityMatches) return @"revoked";
      if (ubiquitous.boolValue &&
          ![downloadStatus isEqual:NSURLUbiquitousItemDownloadingStatusCurrent]) {
        return @"not_downloaded";
      }
      return @"ok";
    } @finally {
      if (scopeStarted) [url stopAccessingSecurityScopedResource];
    }
  }
  if (![record[@"root_locator_kind"] isEqual:@"legacy_app_owned"]) {
    return @"unavailable";
  }
  return [self verifiedLegacyCapabilitiesForRecord:record authority:authority]
      != nil ? @"ok" : @"unavailable";
}

- (nullable NSDictionary *)recordInRegistry:(NSDictionary *)registry
                                  workspaceId:(NSString *)workspaceId {
  for (NSDictionary *record in registry[@"records"]) {
    if ([record[@"workspace_id"] isEqual:workspaceId]) return record;
  }
  return nil;
}

- (BOOL)validReceipt:(NSDictionary *)receipt {
  NSArray *keys = @[
    @"schema_version", @"operation_id", @"workspace_id", @"operation",
    @"binding_revision", @"registry_generation", @"registry_sha256",
    @"request_sha256", @"outcome", @"committed_at",
  ];
  NSSet *operations = [NSSet setWithArray:
      @[@"create", @"import", @"regrant", @"forget", @"delete_owned",
        @"bootstrap_legacy"]];
  BOOL structurallyValid = DSHExactKeys(receipt, keys) &&
      DSHSchemaVersionIsOne(receipt[@"schema_version"]) &&
      DSHCanonicalUUID(receipt[@"operation_id"]) &&
      DSHCanonicalUUID(receipt[@"workspace_id"]) &&
      [operations containsObject:receipt[@"operation"]] &&
      DSHIsSafeInteger(receipt[@"binding_revision"], NO) &&
      DSHIsSafeInteger(receipt[@"registry_generation"], YES) &&
      DSHCanonicalSHA256(receipt[@"registry_sha256"]) &&
      DSHCanonicalSHA256(receipt[@"request_sha256"]) &&
      ([receipt[@"outcome"] isEqual:@"committed"] ||
       [receipt[@"outcome"] isEqual:@"purge_pending"]) &&
      DSHCanonicalTimestamp(receipt[@"committed_at"]);
  if (!structurallyValid) return NO;
  if ([receipt[@"outcome"] isEqual:@"purge_pending"] &&
      ![receipt[@"operation"] isEqual:@"delete_owned"]) {
    return NO;
  }
  if ([receipt[@"operation"] isEqual:@"bootstrap_legacy"] &&
      (![receipt[@"outcome"] isEqual:@"committed"] ||
       ![receipt[@"binding_revision"] isEqual:@1])) {
    return NO;
  }
  return YES;
}

// A1 receipts predate request_sha256.  They remain readable and are not
// rewritten in place: the registry record and authority are the source of
// truth used to validate a retry.  New receipts continue to require the
// request digest above.
- (BOOL)validLegacyReceipt:(NSDictionary *)receipt {
  NSArray *keys = @[
    @"schema_version", @"operation_id", @"workspace_id", @"operation",
    @"binding_revision", @"registry_generation", @"registry_sha256",
    @"outcome", @"committed_at",
  ];
  NSSet *operations = [NSSet setWithArray:
      @[@"create", @"import", @"regrant", @"forget", @"delete_owned",
        @"bootstrap_legacy"]];
  if (!DSHExactKeys(receipt, keys) ||
      !DSHSchemaVersionIsOne(receipt[@"schema_version"]) ||
      !DSHCanonicalUUID(receipt[@"operation_id"]) ||
      !DSHCanonicalUUID(receipt[@"workspace_id"]) ||
      ![operations containsObject:receipt[@"operation"]] ||
      !DSHIsSafeInteger(receipt[@"binding_revision"], NO) ||
      !DSHIsSafeInteger(receipt[@"registry_generation"], YES) ||
      !DSHCanonicalSHA256(receipt[@"registry_sha256"]) ||
      (![receipt[@"outcome"] isEqual:@"committed"] &&
       ![receipt[@"outcome"] isEqual:@"purge_pending"]) ||
      !DSHCanonicalTimestamp(receipt[@"committed_at"])) {
    return NO;
  }
  if ([receipt[@"outcome"] isEqual:@"purge_pending"] &&
      ![receipt[@"operation"] isEqual:@"delete_owned"]) {
    return NO;
  }
  if ([receipt[@"operation"] isEqual:@"bootstrap_legacy"] &&
      (![receipt[@"outcome"] isEqual:@"committed"] ||
       ![receipt[@"binding_revision"] isEqual:@1])) {
    return NO;
  }
  return YES;
}

static NSDictionary *DSHPublicOperationReceipt(NSDictionary *receipt) {
  if (![receipt isKindOfClass:NSDictionary.class]) return nil;
  // request_sha256 is a private idempotency binding. It is intentionally
  // omitted from the public query result even though it remains in the
  // protected receipt store for retry/conflict detection.
  return @{
    @"schema_version" : receipt[@"schema_version"],
    @"operation_id" : receipt[@"operation_id"],
    @"workspace_id" : receipt[@"workspace_id"],
    @"operation" : receipt[@"operation"],
    @"binding_revision" : receipt[@"binding_revision"],
    @"registry_generation" : receipt[@"registry_generation"],
    @"registry_sha256" : receipt[@"registry_sha256"],
    @"outcome" : receipt[@"outcome"],
    @"committed_at" : receipt[@"committed_at"],
  };
}

- (nullable NSMutableArray<NSDictionary *> *)loadReceipts:(NSError **)error {
  NSDictionary *envelope = [self readProtectedObjectAtURL:self.receiptsURL
                                                  maxBytes:DSHWorkspaceReceiptStoreMaxBytes
                                                     error:error];
  if (envelope == nil ||
      !DSHExactKeys(envelope, @[@"schema_version", @"receipts"]) ||
      !DSHSchemaVersionIsOne(envelope[@"schema_version"]) ||
      ![envelope[@"receipts"] isKindOfClass:NSArray.class] ||
      [envelope[@"receipts"] count] > DSHWorkspaceReceiptCapacity) {
    if (envelope != nil) {
      DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    }
    return nil;
  }
  NSMutableArray *result = [NSMutableArray array];
  NSMutableSet *operationIds = [NSMutableSet set];
  for (id receipt in envelope[@"receipts"]) {
    if (![receipt isKindOfClass:NSDictionary.class] ||
        (![self validReceipt:receipt] && ![self validLegacyReceipt:receipt]) ||
        [operationIds containsObject:receipt[@"operation_id"]]) {
      DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
      return nil;
    }
    [operationIds addObject:receipt[@"operation_id"]];
    [result addObject:receipt];
  }
  return result;
}

- (BOOL)pruneReceipts:(NSMutableArray<NSDictionary *> *)receipts
                 write:(BOOL)write
                 error:(NSError **)error {
  NSDate *now = self.clock();
  if (![now isKindOfClass:NSDate.class]) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  NSUInteger before = receipts.count;
  NSIndexSet *expired = [receipts indexesOfObjectsPassingTest:
      ^BOOL(NSDictionary *receipt, NSUInteger index, BOOL *stop) {
        NSDate *committed = [DSHTimestampFormatter()
            dateFromString:receipt[@"committed_at"]];
        return committed == nil ||
               [now timeIntervalSinceDate:committed] > DSHWorkspaceReceiptTTL;
      }];
  [receipts removeObjectsAtIndexes:expired];
  if (write && before != receipts.count) {
    return [self writeProtectedObject:@{@"schema_version" : @1,
                                        @"receipts" : receipts}
                                toURL:self.receiptsURL
                             maxBytes:DSHWorkspaceReceiptStoreMaxBytes
                                error:error];
  }
  return YES;
}

- (nullable NSDictionary *)receiptForOperationId:(NSString *)operationId
                                         receipts:(NSArray<NSDictionary *> *)receipts {
  for (NSDictionary *receipt in receipts) {
    if ([receipt[@"operation_id"] isEqual:operationId]) return receipt;
  }
  return nil;
}

- (BOOL)validJournal:(NSDictionary *)journal {
  NSArray *keys = @[
    @"schema_version", @"operation_id", @"workspace_id", @"operation",
    @"phase", @"binding_revision", @"previous_registry_generation",
    @"previous_registry_sha256", @"authority_sha256", @"record_sha256",
    @"staging_name", @"destination_name", @"display_name",
    @"request_sha256", @"staging_device_id", @"staging_inode_id",
    @"staging_uid", @"staging_gid", @"destination_device_id",
    @"destination_inode_id", @"destination_uid", @"destination_gid",
    @"legacy_project_id", @"clearance_receipt_id", @"confirmation_id",
    @"created_at", @"last_opened_at", @"updated_at",
  ];
  // Task B adds the one Rish-owned creation transaction. Future import,
  // regrant, and destructive journals remain untouched and fail closed until
  // their exact recovery engines ship.
  NSSet *operations = [NSSet setWithArray:@[@"bootstrap_legacy", @"create"]];
  NSSet *phases = [NSSet setWithArray:
      @[@"prepared", @"authority_ready", @"registry_committed"]];
  if (!DSHExactKeys(journal, keys) ||
      !DSHSchemaVersionIsOne(journal[@"schema_version"]) ||
      !DSHCanonicalUUID(journal[@"operation_id"]) ||
      !DSHCanonicalUUID(journal[@"workspace_id"]) ||
      ![operations containsObject:journal[@"operation"]] ||
      ![phases containsObject:journal[@"phase"]] ||
      !DSHIsSafeInteger(journal[@"binding_revision"], NO) ||
      !DSHIsSafeInteger(journal[@"previous_registry_generation"], YES) ||
      !DSHCanonicalSHA256(journal[@"previous_registry_sha256"]) ||
      !DSHCanonicalDisplayName(journal[@"display_name"]) ||
      !DSHCanonicalSHA256(journal[@"request_sha256"]) ||
      !DSHCanonicalTimestamp(journal[@"last_opened_at"]) ||
      !DSHCanonicalTimestamp(journal[@"created_at"]) ||
      !DSHCanonicalTimestamp(journal[@"updated_at"])) {
    return NO;
  }
  BOOL prepared = [journal[@"phase"] isEqual:@"prepared"];
  if (prepared) {
    if (journal[@"authority_sha256"] != NSNull.null ||
        journal[@"record_sha256"] != NSNull.null) return NO;
  } else if (!DSHCanonicalSHA256(journal[@"authority_sha256"]) ||
             !DSHCanonicalSHA256(journal[@"record_sha256"])) {
    return NO;
  }
  NSArray *nullableStrings = @[@"staging_name", @"destination_name",
                               @"clearance_receipt_id", @"confirmation_id",
                               @"staging_device_id", @"staging_inode_id",
                               @"staging_uid", @"staging_gid",
                               @"destination_device_id",
                               @"destination_inode_id", @"destination_uid",
                               @"destination_gid"];
  for (NSString *key in nullableStrings) {
    if (journal[key] != NSNull.null &&
        ![journal[key] isKindOfClass:NSString.class]) return NO;
  }
  NSArray *identityPrefixes = @[@"staging_", @"destination_"];
  for (NSString *prefix in identityPrefixes) {
    NSArray *identityKeys = @[
      [prefix stringByAppendingString:@"device_id"],
      [prefix stringByAppendingString:@"inode_id"],
      [prefix stringByAppendingString:@"uid"],
      [prefix stringByAppendingString:@"gid"],
    ];
    BOOL any = NO;
    BOOL all = YES;
    for (NSString *key in identityKeys) {
      BOOL present = journal[key] != NSNull.null;
      any = any || present;
      all = all && present && DSHCanonicalUnsignedIntegerString(journal[key]);
    }
    if (any != all) return NO;
  }
  if ([journal[@"operation"] isEqual:@"bootstrap_legacy"]) {
    return [journal[@"binding_revision"] isEqual:@1] &&
           DSHCanonicalUUID(journal[@"legacy_project_id"]) &&
           [journal[@"request_sha256"]
               isEqual:DSHBootstrapRequestSHA256(journal[@"legacy_project_id"])] &&
           journal[@"staging_name"] == NSNull.null &&
           journal[@"destination_name"] == NSNull.null &&
           journal[@"staging_device_id"] == NSNull.null &&
           journal[@"staging_inode_id"] == NSNull.null &&
           journal[@"staging_uid"] == NSNull.null &&
           journal[@"staging_gid"] == NSNull.null &&
           journal[@"destination_device_id"] == NSNull.null &&
           journal[@"destination_inode_id"] == NSNull.null &&
           journal[@"destination_uid"] == NSNull.null &&
           journal[@"destination_gid"] == NSNull.null &&
           journal[@"clearance_receipt_id"] == NSNull.null &&
           journal[@"confirmation_id"] == NSNull.null;
  }
  if ([journal[@"operation"] isEqual:@"create"]) {
    return [journal[@"binding_revision"] isEqual:@1] &&
           DSHInternalComponent(journal[@"staging_name"]) &&
           DSHInternalComponent(journal[@"destination_name"]) &&
           ![journal[@"staging_name"] isEqual:journal[@"destination_name"]] &&
           [journal[@"request_sha256"]
               isEqual:DSHCreateRequestSHA256(journal[@"display_name"])] &&
           journal[@"legacy_project_id"] == NSNull.null &&
           journal[@"clearance_receipt_id"] == NSNull.null &&
           journal[@"confirmation_id"] == NSNull.null &&
           (([journal[@"phase"] isEqual:@"prepared"]) ||
            (journal[@"staging_device_id"] != NSNull.null &&
             journal[@"staging_inode_id"] != NSNull.null &&
             journal[@"staging_uid"] != NSNull.null &&
             journal[@"staging_gid"] != NSNull.null &&
             journal[@"destination_device_id"] != NSNull.null &&
             journal[@"destination_inode_id"] != NSNull.null &&
             journal[@"destination_uid"] != NSNull.null &&
             journal[@"destination_gid"] != NSNull.null));
  }
  return NO;
}

// A1 shipped a schema-1 bootstrap journal before Workspace B added the
// request/display-name and filesystem-identity fields.  Keep that exact
// shape readable so an upgrade can finish the already-durable bootstrap; the
// stricter create journal above is still required for every new Files-visible
// transaction.
- (BOOL)validLegacyJournal:(NSDictionary *)journal {
  NSArray *keys = @[
    @"schema_version", @"operation_id", @"workspace_id", @"operation",
    @"phase", @"binding_revision", @"previous_registry_generation",
    @"previous_registry_sha256", @"authority_sha256", @"record_sha256",
    @"staging_name", @"destination_name", @"legacy_project_id",
    @"clearance_receipt_id", @"confirmation_id", @"created_at", @"updated_at",
  ];
  NSSet *phases = [NSSet setWithArray:
      @[@"prepared", @"authority_ready", @"registry_committed"]];
  if (!DSHExactKeys(journal, keys) ||
      !DSHSchemaVersionIsOne(journal[@"schema_version"]) ||
      !DSHCanonicalUUID(journal[@"operation_id"]) ||
      !DSHCanonicalUUID(journal[@"workspace_id"]) ||
      ![journal[@"operation"] isEqual:@"bootstrap_legacy"] ||
      ![phases containsObject:journal[@"phase"]] ||
      !DSHIsSafeInteger(journal[@"binding_revision"], NO) ||
      !DSHIsSafeInteger(journal[@"previous_registry_generation"], YES) ||
      !DSHCanonicalSHA256(journal[@"previous_registry_sha256"]) ||
      !DSHCanonicalTimestamp(journal[@"created_at"]) ||
      !DSHCanonicalTimestamp(journal[@"updated_at"]) ||
      !DSHCanonicalUUID(journal[@"legacy_project_id"]) ||
      journal[@"staging_name"] != NSNull.null ||
      journal[@"destination_name"] != NSNull.null ||
      journal[@"clearance_receipt_id"] != NSNull.null ||
      journal[@"confirmation_id"] != NSNull.null) {
    return NO;
  }
  BOOL prepared = [journal[@"phase"] isEqual:@"prepared"];
  return prepared
      ? (journal[@"authority_sha256"] == NSNull.null &&
         journal[@"record_sha256"] == NSNull.null)
      : (DSHCanonicalSHA256(journal[@"authority_sha256"]) &&
         DSHCanonicalSHA256(journal[@"record_sha256"]));
}

- (nullable NSDictionary *)loadJournalIfPresent:(NSError **)error {
  struct stat state = {};
  if (lstat(self.journalURL.fileSystemRepresentation, &state) != 0) {
    if (errno == ENOENT) return @{};
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return nil;
  }
  NSDictionary *journal = [self readProtectedObjectAtURL:self.journalURL
                                                 maxBytes:DSHWorkspaceAuthorityMaxBytes
                                                    error:error];
  if (journal == nil) return nil;
  if ([self validJournal:journal] || [self validLegacyJournal:journal]) {
    return journal;
  }
  DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
  return nil;
}

- (nullable NSDictionary *)recordReconstructedFromLegacyAuthority:
    (NSDictionary *)authority {
  NSDictionary *record = @{
    @"schema_version" : @1,
    @"workspace_id" : authority[@"workspace_id"],
    @"display_name" : authority[@"display_name"],
    @"origin" : @"legacy_app_owned",
    @"root_locator_kind" : @"legacy_app_owned",
    @"location_class" : @"rish_owned",
    @"owned_directory_name" : NSNull.null,
    @"legacy_project_id" : authority[@"legacy_project_id"],
    @"binding_revision" : authority[@"binding_revision"],
    @"created_at" : authority[@"created_at"],
    @"last_opened_at" : authority[@"last_opened_at"],
  };
  return DSHValidWorkspaceRecord(record) ? record : nil;
}

- (nullable NSDictionary *)recordReconstructedFromCreateJournal:
    (NSDictionary *)journal {
  // Keep the requested display name separate from the allocated directory
  // name. A collision suffix is a filesystem detail, not part of the public
  // WorkspaceDescriptor.
  NSString *displayName = journal[@"display_name"];
  NSString *destination = journal[@"destination_name"];
  NSString *timestamp = journal[@"created_at"];
  if (![journal[@"operation"] isEqual:@"create"] ||
      !DSHCanonicalDisplayName(displayName) ||
      !DSHInternalComponent(destination) ||
      !DSHCanonicalTimestamp(timestamp) ||
      !DSHCanonicalTimestamp(journal[@"last_opened_at"])) {
    return nil;
  }
  NSDictionary *record = @{
    @"schema_version" : @1,
    @"workspace_id" : journal[@"workspace_id"],
    @"display_name" : displayName,
    @"origin" : @"rish_created",
    @"root_locator_kind" : @"documents_owned",
    @"location_class" : @"rish_owned",
    @"owned_directory_name" : destination,
    @"legacy_project_id" : NSNull.null,
    @"binding_revision" : journal[@"binding_revision"],
    @"created_at" : timestamp,
    @"last_opened_at" : journal[@"last_opened_at"],
  };
  return DSHValidWorkspaceRecord(record) ? record : nil;
}

static BOOL DSHJournalIdentityPresent(NSDictionary *journal,
                                      NSString *prefix) {
  NSArray *keys = @[
    [prefix stringByAppendingString:@"device_id"],
    [prefix stringByAppendingString:@"inode_id"],
    [prefix stringByAppendingString:@"uid"],
    [prefix stringByAppendingString:@"gid"],
  ];
  for (NSString *key in keys) {
    if (!DSHCanonicalUnsignedIntegerString(journal[key])) return NO;
  }
  return YES;
}

static BOOL DSHJournalIdentityMatchesState(NSDictionary *journal,
                                           NSString *prefix,
                                           const struct stat &state) {
  if (!DSHJournalIdentityPresent(journal, prefix)) return NO;
  unsigned long long expectedDevice = strtoull(
      [journal[[prefix stringByAppendingString:@"device_id"]] UTF8String],
      NULL, 10);
  unsigned long long expectedInode = strtoull(
      [journal[[prefix stringByAppendingString:@"inode_id"]] UTF8String],
      NULL, 10);
  unsigned long long expectedUID = strtoull(
      [journal[[prefix stringByAppendingString:@"uid"]] UTF8String], NULL, 10);
  unsigned long long expectedGID = strtoull(
      [journal[[prefix stringByAppendingString:@"gid"]] UTF8String], NULL, 10);
  return (unsigned long long)state.st_dev == expectedDevice &&
         (unsigned long long)state.st_ino == expectedInode &&
         (unsigned long long)state.st_uid == expectedUID &&
         (unsigned long long)state.st_gid == expectedGID;
}

static BOOL DSHOwnedAuthorityMatchesJournal(NSDictionary *authority,
                                            NSDictionary *journal) {
  NSString *prefix = DSHJournalIdentityPresent(journal, @"destination_")
      ? @"destination_"
      : @"staging_";
  return [authority[@"device_id"]
              isEqual:journal[[prefix stringByAppendingString:@"device_id"]]] &&
         [authority[@"inode_id"]
              isEqual:journal[[prefix stringByAppendingString:@"inode_id"]]];
}

- (BOOL)inspectCreateArtifactNamed:(NSString *)name
                              state:(struct stat *)stateOut
                             exists:(BOOL *)existsOut
                              error:(NSError **)error {
  if (!DSHInternalComponent(name)) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  NSURL *url = [[self ownedWorkspacesRootURL]
      URLByAppendingPathComponent:name isDirectory:YES];
  struct stat state = {};
  if (lstat(url.fileSystemRepresentation, &state) != 0) {
    if (errno == ENOENT) {
      if (existsOut != nil) *existsOut = NO;
      return YES;
    }
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  if (existsOut != nil) *existsOut = YES;
  if (stateOut != nil) *stateOut = state;
  // Do not broaden this check to regular files. Directory cleanup is only
  // valid for an empty, non-symlink directory; rmdir performs the final
  // emptiness check below.
  if (!S_ISDIR(state.st_mode) || S_ISLNK(state.st_mode) || state.st_nlink < 2) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  return YES;
}

- (BOOL)removeCreateArtifactNamed:(NSString *)name
                           journal:(NSDictionary *)journal
                             error:(NSError **)error {
  if (!DSHInternalComponent(name) ||
      (![name isEqual:journal[@"staging_name"]] &&
       ![name isEqual:journal[@"destination_name"]])) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  NSURL *url = [[self ownedWorkspacesRootURL]
      URLByAppendingPathComponent:name isDirectory:YES];
  struct stat state = {};
  if (lstat(url.fileSystemRepresentation, &state) != 0) {
    if (errno == ENOENT) return YES;
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  if (!S_ISDIR(state.st_mode) || S_ISLNK(state.st_mode) ||
      state.st_nlink < 2) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  NSString *prefix = [name isEqual:journal[@"destination_name"]]
      ? @"destination_"
      : @"staging_";
  // A create journal proves an artifact by identity, never by pathname. For
  // a crash between rename and the destination-identity write, the staging
  // identity remains the durable proof that the destination is ours.
  BOOL identityMatches = DSHJournalIdentityMatchesState(journal, prefix, state) ||
      ([prefix isEqual:@"destination_"] &&
       DSHJournalIdentityMatchesState(journal, @"staging_", state));
  if (!identityMatches) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorConflict);
    return NO;
  }
  if (rmdir(url.fileSystemRepresentation) != 0) {
    // A newly-created root is empty. Never recursively remove a directory
    // whose contents could be user data during journal recovery.
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  return [self fsyncDirectoryURL:[self ownedWorkspacesRootURL]
                           stage:nil
                           error:error];
}

- (BOOL)preflightPublishedAuthoritiesInRegistry:(NSDictionary *)registry
                                           error:(NSError **)error {
  for (NSDictionary *publishedRecord in registry[@"records"]) {
    if ([self loadAuthorityForRecord:publishedRecord error:error] == nil) {
      return NO;
    }
  }
  return YES;
}

- (BOOL)recoverCreateJournal:(NSDictionary *)journal error:(NSError **)error {
  if (![self ensureOwnedDocumentsLayout:error]) return NO;
  NSDictionary *registry = [self loadRegistry:error digest:nil];
  if (registry == nil) return NO;
  NSString *workspaceId = journal[@"workspace_id"];
  NSDictionary *referenced = [self recordInRegistry:registry
                                         workspaceId:workspaceId];
  NSString *stagingName = journal[@"staging_name"];
  NSString *destinationName = journal[@"destination_name"];
  NSString *phase = journal[@"phase"];
  if ([phase isEqual:@"prepared"]) {
    if (referenced != nil &&
        [referenced[@"binding_revision"]
            isEqual:journal[@"binding_revision"]]) {
      DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
      return NO;
    }

    // Before authority publication, either name may exist due to a crash or
    // an external race.  A pathname is not proof of ownership: only an
    // identity recorded for our staging directory can authorize cleanup.  In
    // particular, never rmdir an empty user directory that won the
    // RENAME_EXCL race.
    BOOL stagingExists = NO;
    BOOL destinationExists = NO;
    struct stat stagingState = {};
    struct stat destinationState = {};
    if (![self inspectCreateArtifactNamed:stagingName
                                    state:&stagingState
                                   exists:&stagingExists
                                    error:error] ||
        ![self inspectCreateArtifactNamed:destinationName
                                    state:&destinationState
                                   exists:&destinationExists
                                    error:error]) {
      return NO;
    }
    BOOL hasStagingIdentity =
        DSHJournalIdentityPresent(journal, @"staging_");
    BOOL hasDestinationIdentity =
        DSHJournalIdentityPresent(journal, @"destination_");
    if ((stagingExists &&
         (!hasStagingIdentity ||
          !DSHJournalIdentityMatchesState(journal, @"staging_", stagingState))) ||
        (destinationExists &&
         ((!hasDestinationIdentity && !hasStagingIdentity) ||
          (!hasDestinationIdentity &&
           !DSHJournalIdentityMatchesState(journal, @"staging_",
                                           destinationState)) ||
          (hasDestinationIdentity &&
           !DSHJournalIdentityMatchesState(journal, @"destination_",
                                           destinationState))))) {
      DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorConflict);
      return NO;
    }
    if (stagingExists && destinationExists &&
        !DSHSameNode(stagingState, destinationState)) {
      DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorConflict);
      return NO;
    }
    if (stagingExists && destinationExists) {
      // Two names for one directory are not expected from RENAME_EXCL and
      // cannot be safely classified after a crash. Preserve all evidence.
      DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorConflict);
      return NO;
    }
    NSURL *authorityURL = [self authorityURLForKind:@"owned"
                                         workspaceId:workspaceId
                                            revision:journal[@"binding_revision"]];
    struct stat authorityState = {};
    BOOL authorityExists =
        lstat(authorityURL.fileSystemRepresentation, &authorityState) == 0;
    if (!authorityExists && errno != ENOENT) {
      DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
      return NO;
    }
    NSDictionary *preparedAuthority = nil;
    if (authorityExists) {
      NSDictionary *candidate = [self readProtectedObjectAtURL:authorityURL
                                                       maxBytes:DSHWorkspaceAuthorityMaxBytes
                                                          error:error];
      NSDictionary *candidateRecord =
          [self recordReconstructedFromCreateJournal:journal];
      if (candidate == nil || candidateRecord == nil ||
          !DSHValidOwnedAuthority(candidate, candidateRecord) ||
          !DSHOwnedAuthorityMatchesJournal(candidate, journal)) {
        if (error != nil && *error == nil) {
          DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        }
        return NO;
      }
      preparedAuthority = candidate;
    }
    if (stagingExists &&
        ![self removeCreateArtifactNamed:stagingName
                                  journal:journal
                                    error:error]) {
      return NO;
    }
    if (destinationExists &&
        ![self removeCreateArtifactNamed:destinationName
                                  journal:journal
                                    error:error]) {
      return NO;
    }
    if (preparedAuthority != nil &&
        ![self removeProtectedURL:authorityURL error:error]) {
      return NO;
    }
    return [self removeProtectedURL:self.journalURL error:error];
  }

  NSURL *authorityURL = [self authorityURLForKind:@"owned"
                                       workspaceId:workspaceId
                                          revision:journal[@"binding_revision"]];
  NSDictionary *authority = [self readProtectedObjectAtURL:authorityURL
                                                   maxBytes:DSHWorkspaceAuthorityMaxBytes
                                                      error:error];
  NSDictionary *record = [self recordReconstructedFromCreateJournal:journal];
  if (authority == nil || record == nil ||
      !DSHValidOwnedAuthority(authority, record) ||
      ![self validateOwnedRootForRecord:record authority:authority error:error] ||
      ![DSHSHA256(DSHCanonicalJSON(authority))
          isEqual:journal[@"authority_sha256"]]) {
    if (error != nil && *error == nil) {
      DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    }
    return NO;
  }
  if (![DSHSHA256(DSHCanonicalJSON(record))
          isEqual:journal[@"record_sha256"]]) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  NSString *registryDigest = nil;
  registry = [self loadRegistry:error digest:&registryDigest];
  if (registry == nil) return NO;
  // Recovery must use the same all-record authority preflight as a fresh
  // create. Publishing one more record into a registry that already contains
  // a corrupted authority would make every subsequent metadata read fail
  // closed while leaving the new transaction partially committed.
  if (![self preflightPublishedAuthoritiesInRegistry:registry error:error]) {
    return NO;
  }
  unsigned long long previousGeneration =
      [journal[@"previous_registry_generation"] unsignedLongLongValue];
  BOOL registryIsPrevious =
      [registry[@"generation"]
          isEqual:journal[@"previous_registry_generation"]] &&
      [registryDigest isEqual:journal[@"previous_registry_sha256"]];
  NSDictionary *published = [self recordInRegistry:registry
                                          workspaceId:workspaceId];
  BOOL registryAlreadyPublished =
      previousGeneration < DSHWorkspaceMaxSafeInteger &&
      [registry[@"generation"] unsignedLongLongValue] == previousGeneration + 1 &&
      published != nil &&
      [DSHSHA256(DSHCanonicalJSON(published))
          isEqual:journal[@"record_sha256"]];
  if ([phase isEqual:@"authority_ready"]) {
    if (!registryIsPrevious && !registryAlreadyPublished) {
      if (published != nil &&
          [published[@"binding_revision"]
              isEqual:journal[@"binding_revision"]]) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        return NO;
      }
      if (![self removeCreateArtifactNamed:destinationName
                                    journal:journal
                                      error:error] ||
          ![self removeProtectedURL:authorityURL error:error] ||
          ![self removeProtectedURL:self.journalURL error:error]) {
        return NO;
      }
      return YES;
    }
    if (registryIsPrevious &&
        ![self writeRegistryFromPrevious:registry record:record error:error]) {
      return NO;
    }
    NSMutableDictionary *committed = [journal mutableCopy];
    committed[@"phase"] = @"registry_committed";
    committed[@"updated_at"] = DSHCanonicalTimestampForDate(self.clock());
    if (![self writeProtectedObject:committed toURL:self.journalURL
                           maxBytes:DSHWorkspaceAuthorityMaxBytes
                              error:error]) {
      return NO;
    }
    journal = committed;
  }
  if ([journal[@"phase"] isEqual:@"registry_committed"]) {
    return [self finishCommittedJournal:journal error:error];
  }
  DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
  return NO;
}

- (BOOL)writeRegistryFromPrevious:(NSDictionary *)previous
                            record:(NSDictionary *)record
                             error:(NSError **)error {
  NSMutableArray *records = [previous[@"records"] mutableCopy];
  NSIndexSet *matching = [records indexesOfObjectsPassingTest:
      ^BOOL(NSDictionary *candidate, NSUInteger index, BOOL *stop) {
        return [candidate[@"workspace_id"] isEqual:record[@"workspace_id"]];
      }];
  if (matching.count > 1) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  if (matching.count == 1) {
    [records replaceObjectAtIndex:matching.firstIndex withObject:record];
  } else {
    if (records.count >= DSHWorkspaceRegistryMaxRecords) {
      DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorBusy);
      return NO;
    }
    [records addObject:record];
  }
  [records sortUsingComparator:^NSComparisonResult(NSDictionary *left,
                                                    NSDictionary *right) {
    return [left[@"workspace_id"] compare:right[@"workspace_id"]];
  }];
  unsigned long long generation = [previous[@"generation"] unsignedLongLongValue];
  if (generation >= DSHWorkspaceMaxSafeInteger) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  return [self writeProtectedObject:@{
    @"schema_version" : @1,
    @"generation" : @(generation + 1),
    @"records" : records,
  } toURL:self.registryURL maxBytes:DSHWorkspaceRegistryMaxBytes error:error];
}

- (BOOL)finishCommittedJournal:(NSDictionary *)journal error:(NSError **)error {
  NSString *registryDigest = nil;
  NSDictionary *registry = [self loadRegistry:error digest:&registryDigest];
  if (registry == nil) return NO;
  if (![self preflightPublishedAuthoritiesInRegistry:registry error:error]) {
    return NO;
  }
  NSDictionary *record = [self recordInRegistry:registry
                                     workspaceId:journal[@"workspace_id"]];
  if (record == nil ||
      ![DSHSHA256(DSHCanonicalJSON(record)) isEqual:journal[@"record_sha256"]]) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  NSDictionary *authority = [self loadAuthorityForRecord:record error:error];
  if (authority == nil) return NO;
  NSDictionary *digestObject = authority[@"bookmark"] == nil ? authority
                                                               : authority[@"granted"];
  if (![DSHSHA256(DSHCanonicalJSON(digestObject))
          isEqual:journal[@"authority_sha256"]]) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  NSMutableArray *receipts = [self loadReceipts:error];
  if (receipts == nil || ![self pruneReceipts:receipts write:NO error:error]) {
    return NO;
  }
  NSDictionary *existing = [self receiptForOperationId:journal[@"operation_id"]
                                               receipts:receipts];
  if (existing != nil) {
    id journalRequestSHA256 = journal[@"request_sha256"];
    id existingRequestSHA256 = existing[@"request_sha256"];
    BOOL requestBindingMatches =
        (journalRequestSHA256 == nil && existingRequestSHA256 == nil) ||
        (journalRequestSHA256 != nil && existingRequestSHA256 != nil &&
         [existingRequestSHA256 isEqual:journalRequestSHA256]);
    if (![existing[@"workspace_id"] isEqual:journal[@"workspace_id"]] ||
        ![existing[@"operation"] isEqual:journal[@"operation"]] ||
        ![existing[@"binding_revision"] isEqual:journal[@"binding_revision"]] ||
        !requestBindingMatches ||
        ![existing[@"outcome"] isEqual:@"committed"] ||
        ![existing[@"registry_generation"] isEqual:registry[@"generation"]] ||
        ![existing[@"registry_sha256"] isEqual:registryDigest]) {
      DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
      return NO;
    }
  } else {
    if (receipts.count >= DSHWorkspaceReceiptCapacity) {
      DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorBusy);
      return NO;
    }
    NSMutableDictionary *receipt = [@{
      @"schema_version" : @1,
      @"operation_id" : journal[@"operation_id"],
      @"workspace_id" : journal[@"workspace_id"],
      @"operation" : journal[@"operation"],
      @"binding_revision" : journal[@"binding_revision"],
      @"registry_generation" : registry[@"generation"],
      @"registry_sha256" : registryDigest,
      @"outcome" : @"committed",
      @"committed_at" : journal[@"updated_at"],
    } mutableCopy];
    if (journal[@"request_sha256"] != nil) {
      receipt[@"request_sha256"] = journal[@"request_sha256"];
    }
    [receipts addObject:receipt];
    if (![self writeProtectedObject:@{@"schema_version" : @1,
                                      @"receipts" : receipts}
                              toURL:self.receiptsURL
                           maxBytes:DSHWorkspaceReceiptStoreMaxBytes
                              error:error]) {
      return NO;
    }
  }
  if (self.faultHook != nil &&
      self.faultHook(@"after_receipt_written_before_journal_clear")) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  return [self removeProtectedURL:self.journalURL error:error];
}

- (BOOL)recoverJournal:(NSError **)error {
  NSDictionary *journal = [self loadJournalIfPresent:error];
  if (journal == nil) return NO;
  if (journal.count == 0) return YES;
  if ([journal[@"operation"] isEqual:@"create"]) {
    return [self recoverCreateJournal:journal error:error];
  }
  NSString *phase = journal[@"phase"];
  NSURL *authorityURL = [self authorityURLForKind:@"legacy"
                                       workspaceId:journal[@"workspace_id"]
                                          revision:journal[@"binding_revision"]];
  if ([phase isEqual:@"prepared"]) {
    NSDictionary *registry = [self loadRegistry:error digest:nil];
    if (registry == nil) return NO;
    NSDictionary *referenced = [self recordInRegistry:registry
                                           workspaceId:journal[@"workspace_id"]];
    if (referenced != nil &&
        [referenced[@"binding_revision"]
            isEqual:journal[@"binding_revision"]]) {
      DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
      return NO;
    }
    NSError *cleanupError = nil;
    if (![self removeProtectedURL:authorityURL error:&cleanupError]) {
      DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
      return NO;
    }
    return [self removeProtectedURL:self.journalURL error:error];
  }
  struct stat authorityState = {};
  if (lstat(authorityURL.fileSystemRepresentation, &authorityState) != 0) {
    if (errno == ENOENT && [phase isEqual:@"authority_ready"]) {
      NSDictionary *registry = [self loadRegistry:error digest:nil];
      if (registry == nil) return NO;
      NSDictionary *referenced = [self recordInRegistry:registry
                                             workspaceId:journal[@"workspace_id"]];
      if (referenced == nil ||
          ![referenced[@"binding_revision"]
              isEqual:journal[@"binding_revision"]]) {
        return [self removeProtectedURL:self.journalURL error:error];
      }
    }
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  NSDictionary *authority = [self readProtectedObjectAtURL:authorityURL
                                                   maxBytes:DSHWorkspaceAuthorityMaxBytes
                                                      error:error];
  NSDictionary *record = authority == nil ? nil :
      [self recordReconstructedFromLegacyAuthority:authority];
  if (record == nil || !DSHValidLegacyAuthority(authority, record) ||
      ![DSHSHA256(DSHCanonicalJSON(authority))
          isEqual:journal[@"authority_sha256"]] ||
      ![DSHSHA256(DSHCanonicalJSON(record)) isEqual:journal[@"record_sha256"]]) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  if ([phase isEqual:@"authority_ready"]) {
    NSString *registryDigest = nil;
    NSDictionary *registry = [self loadRegistry:error digest:&registryDigest];
    if (registry == nil) return NO;
    if (![self preflightPublishedAuthoritiesInRegistry:registry error:error]) {
      return NO;
    }
    BOOL registryIsPrevious =
        [registry[@"generation"]
            isEqual:journal[@"previous_registry_generation"]] &&
        [registryDigest isEqual:journal[@"previous_registry_sha256"]];
    unsigned long long previousGeneration =
        [journal[@"previous_registry_generation"] unsignedLongLongValue];
    NSDictionary *publishedRecord = [self recordInRegistry:registry
                                                workspaceId:journal[@"workspace_id"]];
    BOOL registryAlreadyPublished =
        previousGeneration < DSHWorkspaceMaxSafeInteger &&
        [registry[@"generation"] unsignedLongLongValue] == previousGeneration + 1 &&
        publishedRecord != nil &&
        [DSHSHA256(DSHCanonicalJSON(publishedRecord))
            isEqual:journal[@"record_sha256"]];
    if (!registryIsPrevious && !registryAlreadyPublished) {
      // It is safe to remove the staged authority only when the current
      // registry does not reference it. If it does, preserve all evidence and
      // fail closed instead of manufacturing a dangling published record.
      if (publishedRecord != nil &&
          [publishedRecord[@"binding_revision"]
              isEqual:journal[@"binding_revision"]]) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        return NO;
      }
      NSError *cleanupError = nil;
      if (![self removeProtectedURL:authorityURL error:&cleanupError]) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        return NO;
      }
      return [self removeProtectedURL:self.journalURL error:error];
    }
    if (registryIsPrevious &&
        ![self writeRegistryFromPrevious:registry record:record error:error]) {
      return NO;
    }
    NSMutableDictionary *committed = [journal mutableCopy];
    committed[@"phase"] = @"registry_committed";
    committed[@"updated_at"] = DSHCanonicalTimestampForDate(self.clock());
    if (![self writeProtectedObject:committed toURL:self.journalURL
                            maxBytes:DSHWorkspaceAuthorityMaxBytes error:error]) {
      return NO;
    }
    journal = committed;
  }
  if ([journal[@"phase"] isEqual:@"registry_committed"]) {
    return [self finishCommittedJournal:journal error:error];
  }
  DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
  return NO;
}

- (BOOL)ensurePrivateLayoutLocked:(NSError **)error {
  if (![self validateRootIdentity:error] ||
      ![self secureDirectoryAtURL:self.workspaceStoreURL error:error] ||
      ![self secureDirectoryAtURL:self.bindingsStoreURL error:error]) {
    return NO;
  }
  struct stat state = {};
  BOOL manifestExists =
      lstat(self.layoutManifestURL.fileSystemRepresentation, &state) == 0;
  if (!manifestExists && errno != ENOENT) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  BOOL registryExists =
      lstat(self.registryURL.fileSystemRepresentation, &state) == 0;
  if (!registryExists && errno != ENOENT) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  BOOL receiptsExist =
      lstat(self.receiptsURL.fileSystemRepresentation, &state) == 0;
  if (!receiptsExist && errno != ENOENT) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  if (manifestExists) {
    NSDictionary *manifest = [self readProtectedObjectAtURL:self.layoutManifestURL
                                                   maxBytes:4096 error:error];
    if (manifest == nil ||
        !DSHExactKeys(manifest, @[@"schema_version", @"initialized_at"]) ||
        !DSHSchemaVersionIsOne(manifest[@"schema_version"]) ||
        !DSHCanonicalTimestamp(manifest[@"initialized_at"]) ||
        !registryExists || !receiptsExist) {
      if (manifest != nil && error != nil && *error == nil) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
      }
      return NO;
    }
  } else {
    struct stat journalState = {};
    BOOL journalExists =
        lstat(self.journalURL.fileSystemRepresentation, &journalState) == 0;
    NSArray<NSURL *> *bindingEntries = [NSFileManager.defaultManager
        contentsOfDirectoryAtURL:self.bindingsStoreURL
      includingPropertiesForKeys:nil options:0 error:nil];
    if (journalExists || bindingEntries == nil || bindingEntries.count != 0) {
      DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
      return NO;
    }
    if (registryExists) {
      NSDictionary *registry = [self loadRegistry:error digest:nil];
      if (registry == nil || ![registry[@"generation"] isEqual:@0] ||
          [registry[@"records"] count] != 0) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        return NO;
      }
    } else if (![self writeProtectedObject:@{
        @"schema_version" : @1, @"generation" : @0, @"records" : @[]}
        toURL:self.registryURL maxBytes:DSHWorkspaceRegistryMaxBytes error:error]) {
      return NO;
    }
    if (receiptsExist) {
      NSMutableArray *receipts = [self loadReceipts:error];
      if (receipts == nil || receipts.count != 0) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        return NO;
      }
    } else if (![self writeProtectedObject:@{
        @"schema_version" : @1, @"receipts" : @[]}
        toURL:self.receiptsURL maxBytes:DSHWorkspaceReceiptStoreMaxBytes
        error:error]) {
      return NO;
    }
    NSString *initializedAt = DSHCanonicalTimestampForDate(self.clock());
    if (initializedAt == nil || ![self writeProtectedObject:@{
        @"schema_version" : @1, @"initialized_at" : initializedAt}
        toURL:self.layoutManifestURL maxBytes:4096 error:error]) {
      if (error != nil && *error == nil) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
      }
      return NO;
    }
  }
  if (!self.bootstrapped) {
    if (![self recoverJournal:error]) return NO;
    NSMutableArray *receipts = [self loadReceipts:error];
    if (receipts == nil || ![self pruneReceipts:receipts write:YES error:error]) {
      return NO;
    }
    self.bootstrapped = YES;
  } else {
    // A journal may appear after this instance bootstrapped (for example after
    // an injected crash boundary). Validate it on every entry, but recovery is
    // reserved for a fresh instance so pre-publication state stays invisible.
    if ([self loadJournalIfPresent:error] == nil) return NO;
  }
  return YES;
}

- (BOOL)ensurePrivateLayoutWithError:(NSError **)error {
  @try {
    @synchronized(DSHLocalWorkspaceAccess.class) {
      __attribute__((objc_precise_lifetime))
      DSHLocalWorkspaceAuthorityLock *lock = [self acquireAuthorityLock:error];
      if (lock == nil) return NO;
      return [self ensurePrivateLayoutLocked:error];
    }
  } @catch (__unused NSException *exception) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
}

- (nullable NSArray<NSDictionary *> *)listWorkspaceMetadataWithError:
    (NSError **)error {
  @try {
    @synchronized(DSHLocalWorkspaceAccess.class) {
      __attribute__((objc_precise_lifetime))
      DSHLocalWorkspaceAuthorityLock *lock = [self acquireAuthorityLock:error];
      if (lock == nil) return nil;
      if (![self ensurePrivateLayoutLocked:error]) return nil;
      NSDictionary *registry = [self loadRegistry:error digest:nil];
      if (registry == nil) return nil;
      NSMutableArray *result = [NSMutableArray array];
      for (NSDictionary *record in registry[@"records"]) {
        NSDictionary *authority = [self loadAuthorityForRecord:record error:error];
        if (authority == nil) return nil;
        NSString *status = [self metadataStatusForRecord:record
                                                authority:authority];
        NSSet<NSString *> *capabilities =
            [self operationalCapabilitiesForMetadataRecord:record
                                                  authority:authority
                                                     status:status];
        [result addObject:[self descriptorForRecord:record
                                             status:status
                                       capabilities:capabilities]];
      }
      return [result copy];
    }
  } @catch (__unused NSException *exception) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return nil;
  }
}

- (nullable NSDictionary *)resolveWorkspaceId:(NSString *)workspaceId
                       expectedBindingRevision:(NSNumber *)revision
                          requiredCapabilities:(NSArray<NSString *> *)capabilities
                                         error:(NSError **)error {
  @try {
    @synchronized(DSHLocalWorkspaceAccess.class) {
      if (!DSHCanonicalUUID(workspaceId) ||
          !DSHCanonicalCapabilitiesArray(capabilities) ||
          (revision != nil && !DSHIsSafeInteger(revision, NO))) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorInvalid);
        return nil;
      }
      __attribute__((objc_precise_lifetime))
      DSHLocalWorkspaceAuthorityLock *lock = [self acquireAuthorityLock:error];
      if (lock == nil) return nil;
      if (![self ensurePrivateLayoutLocked:error]) return nil;
      NSDictionary *registry = [self loadRegistry:error digest:nil];
      if (registry == nil) return nil;
      NSDictionary *record = [self recordInRegistry:registry
                                         workspaceId:workspaceId];
      if (record == nil) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorNotFound);
        return nil;
      }
      if (revision != nil && ![revision isEqual:record[@"binding_revision"]]) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorRevisionStale);
        return nil;
      }
      NSDictionary *authority = [self loadAuthorityForRecord:record error:error];
      if (authority == nil) return nil;
      if (revision == nil) {
        NSString *status = [self metadataStatusForRecord:record
                                                authority:authority];
        return @{
          @"schema_version" : @1,
          @"disposition" : @"direct",
          @"workspace" : [self descriptorForRecord:record
                                             status:status
                                       capabilities:nil],
        };
      }
      NSString *locator = record[@"root_locator_kind"];
      if ([locator isEqual:@"documents_owned"]) {
        int descriptor = [self openOwnedRootDescriptorForRecord:record
                                                       authority:authority
                                                          error:error];
        if (descriptor < 0) return nil;
        close(descriptor);
        NSSet<NSString *> *available =
            [self operationalCapabilitiesForMetadataRecord:record
                                                   authority:authority
                                                      status:@"ok"];
        if (![[NSSet setWithArray:capabilities] isSubsetOfSet:available]) {
          DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorCapability);
          return nil;
        }
        return @{
          @"schema_version" : @1,
          @"disposition" : @"direct",
          @"workspace" : [self descriptorForRecord:record
                                             status:@"ok"
                                       capabilities:available],
        };
      }
      if ([locator isEqual:@"legacy_app_owned"]) {
        NSSet<NSString *> *available =
            [self verifiedLegacyCapabilitiesForRecord:record
                                            authority:authority];
        if (available == nil) {
          DSHSetWorkspaceError(error,
                               DSHLocalWorkspaceAccessErrorUnavailable);
          return nil;
        }
        if (![[NSSet setWithArray:capabilities] isSubsetOfSet:available]) {
          DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorCapability);
          return nil;
        }
        return @{
          @"schema_version" : @1,
          @"disposition" : @"direct",
          @"workspace" : [self descriptorForRecord:record
                                             status:@"ok"
                                       capabilities:available],
        };
      }
      NSString *status = [self metadataStatusForRecord:record
                                               authority:authority];
      if (![status isEqual:@"ok"]) {
        DSHWorkspaceSetOperationalStatusError(status, error);
        return nil;
      }
      NSSet<NSString *> *available =
          [self operationalCapabilitiesForMetadataRecord:record
                                                   authority:authority
                                                      status:status];
      if (![[NSSet setWithArray:capabilities] isSubsetOfSet:available]) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorCapability);
        return nil;
      }
      return @{
        @"schema_version" : @1,
        @"disposition" : @"direct",
        @"workspace" : [self descriptorForRecord:record
                                           status:@"ok"
                                     capabilities:available],
      };
    }
  } @catch (__unused NSException *exception) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
    return nil;
  }
}

static void DSHWorkspaceSetOperationalStatusError(NSString *status,
                                                   NSError **error) {
  if ([status isEqual:@"stale"]) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorStatusStale);
  } else if ([status isEqual:@"revoked"]) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorRevoked);
  } else if ([status isEqual:@"not_downloaded"]) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorNotDownloaded);
  } else {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
  }
}

- (int)openOwnedRootDescriptorForRecord:(NSDictionary *)record
                               authority:(NSDictionary *)authority
                                  error:(NSError **)error {
  if (![record[@"root_locator_kind"] isEqual:@"documents_owned"] ||
      !DSHValidOwnedAuthority(authority, record) ||
      ![self captureDocumentsRootIdentity:error] ||
      ![self validateOwnedRootForRecord:record authority:authority error:error]) {
    if (error != nil && *error == nil) {
      DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
    } else if (error != nil &&
               (*error).code == DSHLocalWorkspaceAccessErrorPersistence) {
      DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
    }
    return -1;
  }
  NSURL *root = [[self ownedWorkspacesRootURL]
      URLByAppendingPathComponent:record[@"owned_directory_name"]
                       isDirectory:YES];
  int descriptor = open(root.fileSystemRepresentation,
                         O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (descriptor < 0) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
    return -1;
  }
  struct stat opened = {};
  if (fstat(descriptor, &opened) != 0 || !S_ISDIR(opened.st_mode) ||
      S_ISLNK(opened.st_mode) || opened.st_nlink < 2) {
    close(descriptor);
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
    return -1;
  }
  if (!DSHWorkspaceDescriptorMatchesAuthority(descriptor, authority)) {
    close(descriptor);
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorRootChanged);
    return -1;
  }
  return descriptor;
}

- (nullable NSDictionary *)terminalValidatedOwnedDescriptorForRecord:
    (NSDictionary *)record
    error:(NSError **)error {
  if (![record[@"root_locator_kind"] isEqual:@"documents_owned"]) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
    return nil;
  }
  NSDictionary *authority = [self loadAuthorityForRecord:record error:error];
  if (authority == nil) return nil;
  int descriptor = [self openOwnedRootDescriptorForRecord:record
                                                 authority:authority
                                                    error:error];
  if (descriptor < 0) return nil;
  BOOL identityMatches = NO;
  @try {
    identityMatches = DSHWorkspaceDescriptorMatchesAuthority(descriptor,
                                                              authority);
  } @finally {
    close(descriptor);
  }
  if (!identityMatches) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorRootChanged);
    return nil;
  }
  NSString *status = [self metadataStatusForRecord:record authority:authority];
  if (![status isEqual:@"ok"]) {
    DSHWorkspaceSetOperationalStatusError(status, error);
    return nil;
  }
  return [self descriptorForRecord:record
                            status:@"ok"
                      capabilities:[self operationalCapabilitiesForMetadataRecord:
                                         record
                                      authority:authority
                                         status:@"ok"]];
}

- (nullable DSHLocalWorkspaceLease *)leaseWorkspaceId:(NSString *)workspaceId
                               expectedBindingRevision:(NSUInteger)revision
                                  requiredCapabilities:(NSSet<NSString *> *)capabilities
                                                 error:(NSError **)error {
  @try {
    @synchronized(DSHLocalWorkspaceAccess.class) {
      if (!DSHCanonicalUUID(workspaceId) || revision == 0 ||
          revision > DSHWorkspaceMaxSafeInteger ||
          !DSHCanonicalCapabilitiesSet(capabilities)) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorInvalid);
        return nil;
      }
      __attribute__((objc_precise_lifetime))
      DSHLocalWorkspaceAuthorityLock *lock = [self acquireAuthorityLock:error];
      if (lock == nil || ![self ensurePrivateLayoutLocked:error]) return nil;
      NSDictionary *registry = [self loadRegistry:error digest:nil];
      if (registry == nil) return nil;
      NSDictionary *record = [self recordInRegistry:registry
                                         workspaceId:workspaceId];
      if (record == nil) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorNotFound);
        return nil;
      }
      if (![record[@"binding_revision"] isEqual:@(revision)]) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorRevisionStale);
        return nil;
      }
      if ([record[@"root_locator_kind"] isEqual:@"security_scoped"]) {
        // Security-scoped roots never return a long-lived descriptor lease.
        // They are served only by performCoordinated... below.
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorCapability);
        return nil;
      }
      NSDictionary *authority = [self loadAuthorityForRecord:record error:error];
      if (authority == nil) return nil;
      NSString *locator = record[@"root_locator_kind"];
      NSSet<NSString *> *available = nil;
      BOOL legacy = [locator isEqual:@"legacy_app_owned"];
      if (legacy) {
        available = [self verifiedLegacyCapabilitiesForRecord:record
                                                     authority:authority];
        if (available == nil) {
          DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
          return nil;
        }
      } else if ([locator isEqual:@"documents_owned"] ||
                 [locator isEqual:@"security_scoped"]) {
        NSString *status = [self metadataStatusForRecord:record
                                                 authority:authority];
        if (![status isEqual:@"ok"]) {
          DSHWorkspaceSetOperationalStatusError(status, error);
          return nil;
        }
        available = [self operationalCapabilitiesForMetadataRecord:record
                                                            authority:authority
                                                               status:status];
      }
      if (![capabilities isSubsetOfSet:available]) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorCapability);
        return nil;
      }
      if (legacy) {
        // The legacy resolver intentionally exposes no filesystem locator.
        // Returning a lease with descriptor -1 would invite a caller to treat
        // the unresolved root as verified authority, so fail closed until the
        // existing project-access lease is available to this resolver.
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
        return nil;
      }
      int descriptor = [self openOwnedRootDescriptorForRecord:record
                                                     authority:authority
                                                        error:error];
      if (descriptor < 0) return nil;
      return [[DSHLocalWorkspaceLease alloc]
          initWithWorkspaceId:workspaceId
             bindingRevision:revision
              rootDescriptor:descriptor
                  supportsGit:[available containsObject:@"git"]
                  supportsProjectContext:[available containsObject:@"project_context"]
                  authorityGuard:@{
                    @"workspace_id" : workspaceId,
                    @"binding_revision" : @(revision),
                    @"root_fingerprint_sha256" :
                        authority[@"root_fingerprint_sha256"] ?: @"",
                  }];
    }
  } @catch (__unused NSException *exception) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
    return nil;
  }
}

- (BOOL)performCoordinatedWorkspaceOperationForId:(NSString *)workspaceId
                          expectedBindingRevision:(NSUInteger)revision
                             requiredCapabilities:(NSSet<NSString *> *)capabilities
                                            block:(BOOL (^)(int rootDescriptor,
                                                            NSError **error))block
                                            error:(NSError **)error {
  @try {
    @synchronized(DSHLocalWorkspaceAccess.class) {
      if (!DSHCanonicalUUID(workspaceId) || revision == 0 ||
          revision > DSHWorkspaceMaxSafeInteger ||
          !DSHCanonicalCapabilitiesSet(capabilities) || block == nil) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorInvalid);
        return NO;
      }
      __attribute__((objc_precise_lifetime))
      DSHLocalWorkspaceAuthorityLock *lock = [self acquireAuthorityLock:error];
      if (lock == nil || ![self ensurePrivateLayoutLocked:error]) return NO;
      NSDictionary *registry = [self loadRegistry:error digest:nil];
      if (registry == nil) return NO;
      NSDictionary *record = [self recordInRegistry:registry
                                         workspaceId:workspaceId];
      if (record == nil) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorNotFound);
        return NO;
      }
      if (![record[@"binding_revision"] isEqual:@(revision)]) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorRevisionStale);
        return NO;
      }
      // Security-scoped roots expose only the capabilities that have a real
      // coordinated native consumer today. Reject unsupported requests before
      // resolving bookmark authority or entering the user's security scope.
      if ([record[@"root_locator_kind"] isEqual:@"security_scoped"] &&
          ![capabilities isSubsetOfSet:
              [NSSet setWithArray:@[@"read", @"write"]]]) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorCapability);
        return NO;
      }
      NSDictionary *authority = [self loadAuthorityForRecord:record error:error];
      if (authority == nil) return NO;
      NSString *locator = record[@"root_locator_kind"];
      if ([locator isEqual:@"legacy_app_owned"]) {
        NSSet<NSString *> *available =
            [self verifiedLegacyCapabilitiesForRecord:record
                                            authority:authority];
        if (available == nil) {
          DSHSetWorkspaceError(error,
                               DSHLocalWorkspaceAccessErrorUnavailable);
          return NO;
        }
        if (![capabilities isSubsetOfSet:available]) {
          DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorCapability);
          return NO;
        }
        // Legacy authority can prove the recorded physical identity but does
        // not provide an open descriptor. Never run a coordinated operation
        // against a sentinel descriptor or collapse that mismatch to a
        // transient availability error.
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorRootChanged);
        return NO;
      }
      NSString *status = [self metadataStatusForRecord:record
                                               authority:authority];
      if (![status isEqual:@"ok"]) {
        DSHWorkspaceSetOperationalStatusError(status, error);
        return NO;
      }
      NSSet<NSString *> *available =
          [self operationalCapabilitiesForMetadataRecord:record
                                                   authority:authority
                                                      status:status];
      if (![capabilities isSubsetOfSet:available]) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorCapability);
        return NO;
      }

      if ([locator isEqual:@"documents_owned"]) {
        int descriptor = [self openOwnedRootDescriptorForRecord:record
                                                       authority:authority
                                                          error:error];
        if (descriptor < 0) return NO;
        NSError *blockError = nil;
        BOOL success = NO;
        @try {
          success = block(descriptor, &blockError);
          if (!DSHWorkspaceDescriptorMatchesAuthority(descriptor, authority)) {
            success = NO;
            blockError = DSHWorkspaceError(
                DSHLocalWorkspaceAccessErrorRootChanged);
          }
        } @catch (__unused NSException *exception) {
          success = NO;
          blockError = DSHWorkspaceError(DSHLocalWorkspaceAccessErrorIO);
        } @finally {
          close(descriptor);
        }
        if (!success && blockError == nil) {
          blockError = DSHWorkspaceError(DSHLocalWorkspaceAccessErrorIO);
        }
        if (!success && blockError != nil) {
          if (error != nil) *error = blockError;
          return NO;
        }
        return success;
      }

      if (![locator isEqual:@"security_scoped"]) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
        return NO;
      }
      NSDictionary *bookmarkAuthority = authority[@"bookmark"];
      NSDictionary *grantedAuthority = authority[@"granted"];
      NSData *bookmark = [[NSData alloc]
          initWithBase64EncodedString:bookmarkAuthority[@"bookmark_bytes_base64"]
                              options:0];
      if (bookmark == nil || bookmark.length > DSHWorkspaceBookmarkMaxBytes) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorRevoked);
        return NO;
      }
      BOOL bookmarkStale = NO;
      NSError *resolutionError = nil;
      NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark
                                             options:
#if TARGET_OS_OSX || TARGET_OS_MACCATALYST
                                                 NSURLBookmarkResolutionWithSecurityScope
#else
                                                 0
#endif
                                       relativeToURL:nil
                                 bookmarkDataIsStale:&bookmarkStale
                                               error:&resolutionError];
      if (url == nil) {
        DSHSetWorkspaceError(error, bookmarkStale
                                      ? DSHLocalWorkspaceAccessErrorStatusStale
                                      : DSHLocalWorkspaceAccessErrorRevoked);
        return NO;
      }
      BOOL scopeStarted = NO;
      @try {
        if (bookmarkStale) {
          DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorStatusStale);
          return NO;
        }
        scopeStarted = [url startAccessingSecurityScopedResource];
        if (!scopeStarted) {
          DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorRevoked);
          return NO;
        }
        __block BOOL operationResult = NO;
        __block NSError *operationError = nil;
        __block BOOL descriptorClosed = NO;
        void (^coordinatedAccessor)(NSURL *) = ^(NSURL *coordinatedURL) {
          int descriptor = -1;
          @try {
            descriptor = open(coordinatedURL.fileSystemRepresentation,
                              O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
            if (descriptor < 0) {
              operationError = DSHWorkspaceError(
                  DSHLocalWorkspaceAccessErrorUnavailable);
              return;
            }
            struct stat state = {};
            unsigned long long expectedDevice = strtoull(
                [grantedAuthority[@"device_id"] UTF8String], nullptr, 10);
            unsigned long long expectedInode = strtoull(
                [grantedAuthority[@"inode_id"] UTF8String], nullptr, 10);
            if (fstat(descriptor, &state) != 0 || !S_ISDIR(state.st_mode) ||
                S_ISLNK(state.st_mode) ||
                (unsigned long long)state.st_dev != expectedDevice ||
                (unsigned long long)state.st_ino != expectedInode) {
              operationError = DSHWorkspaceError(
                  DSHLocalWorkspaceAccessErrorRootChanged);
              return;
            }
            NSError *blockError = nil;
            operationResult = block(descriptor, &blockError);
            if (!DSHWorkspaceDescriptorMatchesAuthority(descriptor,
                                                        grantedAuthority)) {
              operationResult = NO;
              blockError = DSHWorkspaceError(
                  DSHLocalWorkspaceAccessErrorRootChanged);
            }
            if (!operationResult && blockError != nil) {
              operationError = blockError;
            }
          } @catch (__unused NSException *exception) {
            operationResult = NO;
            operationError = DSHWorkspaceError(DSHLocalWorkspaceAccessErrorIO);
          } @finally {
            if (descriptor >= 0) close(descriptor);
            descriptorClosed = YES;
          }
          if (!operationResult && operationError == nil) {
            operationError = DSHWorkspaceError(DSHLocalWorkspaceAccessErrorIO);
          }
        };
        NSFileCoordinator *coordinator =
            [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        NSError *coordinationError = nil;
        if ([capabilities containsObject:@"write"]) {
          [coordinator coordinateWritingItemAtURL:url
                                           options:0
                                             error:&coordinationError
                                        byAccessor:coordinatedAccessor];
        } else {
          [coordinator coordinateReadingItemAtURL:url
                                           options:0
                                             error:&coordinationError
                                        byAccessor:coordinatedAccessor];
        }
        if (!descriptorClosed && operationError == nil) {
          operationError = DSHWorkspaceError(DSHLocalWorkspaceAccessErrorIO);
        }
        if (coordinationError != nil) {
          DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
          return NO;
        }
        if (operationError != nil) {
          if (error != nil) *error = operationError;
          return NO;
        }
        return operationResult;
      } @finally {
        if (scopeStarted) [url stopAccessingSecurityScopedResource];
      }
    }
  } @catch (__unused NSException *exception) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorIO);
    return NO;
  }
}

- (nullable NSDictionary *)queryOperationId:(NSString *)operationId
                                        error:(NSError **)error {
  @try {
    @synchronized(DSHLocalWorkspaceAccess.class) {
      if (!DSHCanonicalUUID(operationId)) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorInvalid);
        return nil;
      }
      __attribute__((objc_precise_lifetime))
      DSHLocalWorkspaceAuthorityLock *lock = [self acquireAuthorityLock:error];
      if (lock == nil) return nil;
      if (![self ensurePrivateLayoutLocked:error]) return nil;
      NSMutableArray *receipts = [self loadReceipts:error];
      if (receipts == nil ||
          ![self pruneReceipts:receipts write:YES error:error]) return nil;
      NSDictionary *receipt = [self receiptForOperationId:operationId
                                                 receipts:receipts];
      if (receipt != nil) {
        return @{@"schema_version" : @1, @"status" : @"committed",
                 @"receipt" : DSHPublicOperationReceipt(receipt)};
      }
      NSDictionary *journal = [self loadJournalIfPresent:error];
      if (journal == nil) return nil;
      if (journal.count > 0 &&
          [journal[@"operation_id"] isEqual:operationId]) {
        return @{@"schema_version" : @1, @"status" : @"in_progress"};
      }
      return @{@"schema_version" : @1, @"status" : @"not_started"};
    }
  } @catch (__unused NSException *exception) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return nil;
  }
}

- (nullable NSDictionary *)commitInternalWorkspaceRecord:(NSDictionary *)record
                                          authorityRecord:(NSDictionary *)authority
                                      verifiedCapabilities:
                                          (NSSet<NSString *> *)capabilities
                                                 operation:(NSString *)operation
                                               operationId:(NSString *)operationId
                                  expectedCurrentRevision:(NSNumber *)revision
                                                     error:(NSError **)error {
  @try {
    @synchronized(DSHLocalWorkspaceAccess.class) {
      if (![operation isEqual:@"bootstrap_legacy"] || revision != nil) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorInvalid);
        return nil;
      }
      if (!DSHCanonicalUUID(operationId) || !DSHValidWorkspaceRecord(record) ||
          ![record[@"root_locator_kind"] isEqual:@"legacy_app_owned"] ||
          !DSHValidLegacyAuthority(authority, record) ||
          !DSHCanonicalCapabilitiesSet(capabilities) ||
          ![record[@"binding_revision"] isEqual:@1]) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorInvalid);
        return nil;
      }
      if (![self ensurePrivateLayoutLocked:error]) return nil;
      NSDictionary *existingJournal = [self loadJournalIfPresent:error];
      if (existingJournal == nil) return nil;
      if (existingJournal.count > 0) {
        if (![existingJournal[@"operation_id"] isEqual:operationId]) {
          DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorBusy);
          return nil;
        }
        if (![self recoverJournal:error]) return nil;
      }
      NSMutableArray *receipts = [self loadReceipts:error];
      if (receipts == nil || ![self pruneReceipts:receipts write:YES error:error]) {
        return nil;
      }
      NSDictionary *priorReceipt = [self receiptForOperationId:operationId
                                                      receipts:receipts];
      if (priorReceipt != nil) {
        NSDictionary *registry = [self loadRegistry:error digest:nil];
        NSDictionary *existing = registry == nil ? nil :
            [self recordInRegistry:registry
                       workspaceId:priorReceipt[@"workspace_id"]];
        NSDictionary *existingAuthority = existing == nil ? nil :
            [self loadAuthorityForRecord:existing error:error];
        if (existing == nil || existingAuthority == nil) {
          DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
          return nil;
        }
        if (![priorReceipt[@"operation"] isEqual:operation] ||
            ![priorReceipt[@"workspace_id"] isEqual:record[@"workspace_id"]] ||
            ![priorReceipt[@"binding_revision"]
                isEqual:record[@"binding_revision"]] ||
            (priorReceipt[@"request_sha256"] != nil &&
             ![priorReceipt[@"request_sha256"]
                 isEqual:DSHBootstrapRequestSHA256(
                     record[@"legacy_project_id"])] ) ||
            ![existing isEqual:record] ||
            ![existingAuthority isEqual:authority]) {
          DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorConflict);
          return nil;
        }
        return [self descriptorForRecord:existing
                                  status:@"ok"
                            capabilities:capabilities];
      }
      if (receipts.count >= DSHWorkspaceReceiptCapacity) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorBusy);
        return nil;
      }
      NSString *registryDigest = nil;
      NSDictionary *registry = [self loadRegistry:error digest:&registryDigest];
      if (registry == nil) return nil;
      if ([registry[@"generation"] unsignedLongLongValue] >=
          DSHWorkspaceMaxSafeInteger) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        return nil;
      }
      NSDictionary *current = [self recordInRegistry:registry
                                          workspaceId:record[@"workspace_id"]];
      if (current == nil &&
          [registry[@"records"] count] >= DSHWorkspaceRegistryMaxRecords) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorBusy);
        return nil;
      }
      if (current != nil) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorConflict);
        return nil;
      }
      for (NSDictionary *published in registry[@"records"]) {
        if ([self loadAuthorityForRecord:published error:error] == nil) {
          return nil;
        }
      }
      NSString *timestamp = DSHCanonicalTimestampForDate(self.clock());
      if (timestamp == nil) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        return nil;
      }
      NSMutableDictionary *journal = [@{
        @"schema_version" : @1,
        @"operation_id" : operationId,
        @"workspace_id" : record[@"workspace_id"],
        @"operation" : operation,
        @"phase" : @"prepared",
        @"binding_revision" : record[@"binding_revision"],
        @"previous_registry_generation" : registry[@"generation"],
        @"previous_registry_sha256" : registryDigest,
        @"authority_sha256" : NSNull.null,
        @"record_sha256" : NSNull.null,
        @"staging_name" : NSNull.null,
        @"destination_name" : NSNull.null,
        @"display_name" : record[@"display_name"],
        @"request_sha256" :
            DSHBootstrapRequestSHA256(record[@"legacy_project_id"]),
        @"staging_device_id" : NSNull.null,
        @"staging_inode_id" : NSNull.null,
        @"staging_uid" : NSNull.null,
        @"staging_gid" : NSNull.null,
        @"destination_device_id" : NSNull.null,
        @"destination_inode_id" : NSNull.null,
        @"destination_uid" : NSNull.null,
        @"destination_gid" : NSNull.null,
        @"legacy_project_id" : [operation isEqual:@"bootstrap_legacy"]
            ? record[@"legacy_project_id"] : NSNull.null,
        @"clearance_receipt_id" : NSNull.null,
        @"confirmation_id" : NSNull.null,
        @"created_at" : timestamp,
        @"last_opened_at" : record[@"last_opened_at"],
        @"updated_at" : timestamp,
      } mutableCopy];
      if (![self writeProtectedObject:journal toURL:self.journalURL
                              maxBytes:DSHWorkspaceAuthorityMaxBytes error:error]) {
        return nil;
      }
      if (self.faultHook != nil && self.faultHook(@"after_journal_prepared")) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        return nil;
      }
      NSURL *authorityURL = [self authorityURLForKind:@"legacy"
                                           workspaceId:record[@"workspace_id"]
                                              revision:record[@"binding_revision"]];
      if (![self writeProtectedObject:authority toURL:authorityURL
                              maxBytes:DSHWorkspaceAuthorityMaxBytes error:error]) {
        return nil;
      }
      if (self.faultHook != nil &&
          self.faultHook(@"after_authority_write_before_journal")) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        return nil;
      }
      journal[@"phase"] = @"authority_ready";
      journal[@"authority_sha256"] = DSHSHA256(DSHCanonicalJSON(authority));
      journal[@"record_sha256"] = DSHSHA256(DSHCanonicalJSON(record));
      journal[@"updated_at"] = DSHCanonicalTimestampForDate(self.clock());
      if (![self writeProtectedObject:journal toURL:self.journalURL
                              maxBytes:DSHWorkspaceAuthorityMaxBytes error:error]) {
        return nil;
      }
      if (self.faultHook != nil && self.faultHook(@"after_authority_ready")) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        return nil;
      }
      NSString *currentDigest = nil;
      NSDictionary *currentRegistry = [self loadRegistry:error digest:&currentDigest];
      if (currentRegistry == nil) return nil;
      if (![currentRegistry[@"generation"] isEqual:registry[@"generation"]] ||
          ![currentDigest isEqual:registryDigest]) {
        NSDictionary *referenced = [self recordInRegistry:currentRegistry
                                               workspaceId:record[@"workspace_id"]];
        if (referenced != nil &&
            [referenced[@"binding_revision"]
                isEqual:record[@"binding_revision"]]) {
          DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
          return nil;
        }
        NSError *cleanupError = nil;
        if (![self removeProtectedURL:authorityURL error:&cleanupError] ||
            ![self removeProtectedURL:self.journalURL error:&cleanupError]) {
          DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
          return nil;
        }
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorConflict);
        return nil;
      }
      if (![self writeRegistryFromPrevious:currentRegistry record:record error:error]) {
        return nil;
      }
      if (self.faultHook != nil &&
          self.faultHook(@"after_registry_publication_before_journal")) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        return nil;
      }
      journal[@"phase"] = @"registry_committed";
      journal[@"updated_at"] = DSHCanonicalTimestampForDate(self.clock());
      if (![self writeProtectedObject:journal toURL:self.journalURL
                              maxBytes:DSHWorkspaceAuthorityMaxBytes error:error]) {
        return nil;
      }
      if (self.faultHook != nil && self.faultHook(@"after_registry_committed")) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        return nil;
      }
      if (![self finishCommittedJournal:journal error:error]) return nil;
      return [self descriptorForRecord:record
                                status:@"ok"
                          capabilities:capabilities];
    }
  } @catch (__unused NSException *exception) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return nil;
  }
}

- (nullable NSDictionary *)descriptorForBootstrapReceipt:(NSDictionary *)receipt
                                                 projectId:(NSString *)projectId
                                                      error:(NSError **)error {
  NSDictionary *registry = [self loadRegistry:error digest:nil];
  NSDictionary *record = registry == nil ? nil :
      [self recordInRegistry:registry workspaceId:receipt[@"workspace_id"]];
  if (record == nil) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return nil;
  }
  if (![receipt[@"operation"] isEqual:@"bootstrap_legacy"] ||
      ![record[@"legacy_project_id"] isEqual:projectId] ||
      (receipt[@"request_sha256"] != nil &&
       ![receipt[@"request_sha256"]
           isEqual:DSHBootstrapRequestSHA256(projectId)])) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorConflict);
    return nil;
  }
  NSDictionary *authority = [self loadAuthorityForRecord:record error:error];
  if (authority == nil) return nil;
  NSSet<NSString *> *capabilities =
      [NSSet setWithArray:authority[@"capabilities"]];
  return [self descriptorForRecord:record
                            status:@"ok"
                      capabilities:capabilities];
}

- (nullable NSDictionary *)bootstrapLegacyProjectId:(NSString *)projectId
                                          operationId:(NSString *)operationId
                                                error:(NSError **)error {
  @try {
    @synchronized(DSHLocalWorkspaceAccess.class) {
      if (!DSHCanonicalUUID(projectId) || !DSHCanonicalUUID(operationId)) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorInvalid);
        return nil;
      }
      __attribute__((objc_precise_lifetime))
      DSHLocalWorkspaceAuthorityLock *lock = [self acquireAuthorityLock:error];
      if (lock == nil) return nil;
      if (![self ensurePrivateLayoutLocked:error]) return nil;
      NSMutableArray *receipts = [self loadReceipts:error];
      if (receipts == nil || ![self pruneReceipts:receipts write:YES error:error]) {
        return nil;
      }
      NSDictionary *receipt = [self receiptForOperationId:operationId
                                                  receipts:receipts];
      if (receipt != nil) {
        return [self descriptorForBootstrapReceipt:receipt
                                          projectId:projectId
                                              error:error];
      }
      NSDictionary *pendingJournal = [self loadJournalIfPresent:error];
      if (pendingJournal == nil) return nil;
      BOOL pendingMustCommit = NO;
      if (pendingJournal.count > 0) {
        if (![pendingJournal[@"operation_id"] isEqual:operationId]) {
          DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorBusy);
          return nil;
        }
        if (![pendingJournal[@"operation"] isEqual:@"bootstrap_legacy"] ||
            ![pendingJournal[@"legacy_project_id"] isEqual:projectId]) {
          DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorConflict);
          return nil;
        }
        NSString *phase = pendingJournal[@"phase"];
        pendingMustCommit = ![phase isEqual:@"prepared"];
        NSURL *authorityURL = [self authorityURLForKind:@"legacy"
            workspaceId:pendingJournal[@"workspace_id"]
            revision:pendingJournal[@"binding_revision"]];
        struct stat authorityState = {};
        BOOL authorityExists =
            lstat(authorityURL.fileSystemRepresentation, &authorityState) == 0;
        if (authorityExists) {
          NSDictionary *authority = [self readProtectedObjectAtURL:authorityURL
              maxBytes:DSHWorkspaceAuthorityMaxBytes error:error];
          NSDictionary *record = authority == nil ? nil :
              [self recordReconstructedFromLegacyAuthority:authority];
          if (record == nil || !DSHValidLegacyAuthority(authority, record)) {
            if (error != nil && *error == nil) {
              DSHSetWorkspaceError(error,
                                   DSHLocalWorkspaceAccessErrorPersistence);
            }
            return nil;
          }
          if (![record[@"workspace_id"]
                  isEqual:pendingJournal[@"workspace_id"]] ||
              ![record[@"binding_revision"]
                  isEqual:pendingJournal[@"binding_revision"]] ||
              ![record[@"legacy_project_id"] isEqual:projectId]) {
            DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorConflict);
            return nil;
          }
        } else if (errno != ENOENT || pendingMustCommit) {
          DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
          return nil;
        }
        if (![self recoverJournal:error]) return nil;
      }
      receipts = [self loadReceipts:error];
      if (receipts == nil || ![self pruneReceipts:receipts write:YES error:error]) {
        return nil;
      }
      receipt = [self receiptForOperationId:operationId receipts:receipts];
      if (receipt != nil) {
        return [self descriptorForBootstrapReceipt:receipt
                                          projectId:projectId
                                              error:error];
      }
      if (pendingMustCommit) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        return nil;
      }
      NSDictionary *registry = [self loadRegistry:error digest:nil];
      if (registry == nil) return nil;
      for (NSDictionary *candidate in registry[@"records"]) {
        if ([candidate[@"legacy_project_id"] isEqual:projectId]) {
          DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorConflict);
          return nil;
        }
      }
      NSDictionary *evidence =
          [self verifiedLegacyEvidenceForProjectId:projectId];
      if (evidence == nil) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
        return nil;
      }
      NSString *displayName = evidence[@"display_name"];
      NSString *identity = evidence[@"metadata_sha256"];
      NSSet<NSString *> *capabilities = evidence[@"capabilities"];
      NSString *workspaceId = self.UUIDGenerator();
      NSString *timestamp = DSHCanonicalTimestampForDate(self.clock());
      if (!DSHCanonicalUUID(workspaceId) || timestamp == nil ||
          [self recordInRegistry:registry workspaceId:workspaceId] != nil) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        return nil;
      }
      NSDictionary *record = @{
        @"schema_version" : @1,
        @"workspace_id" : workspaceId,
        @"display_name" : displayName,
        @"origin" : @"legacy_app_owned",
        @"root_locator_kind" : @"legacy_app_owned",
        @"location_class" : @"rish_owned",
        @"owned_directory_name" : NSNull.null,
        @"legacy_project_id" : projectId,
        @"binding_revision" : @1,
        @"created_at" : timestamp,
        @"last_opened_at" : timestamp,
      };
      NSDictionary *authorityBase = @{
        @"schema_version" : @1,
        @"workspace_id" : workspaceId,
        @"binding_revision" : @1,
        @"legacy_project_id" : projectId,
        @"root_identity_sha256" : identity,
        @"display_name" : displayName,
        @"capabilities" : [DSHCapabilityOrder()
            filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:
                ^BOOL(NSString *capability, __unused NSDictionary *bindings) {
                  return [capabilities containsObject:capability];
                }]],
        @"created_at" : timestamp,
        @"last_opened_at" : timestamp,
        @"recorded_at" : timestamp,
        @"project_metadata_sha256" : evidence[@"metadata_sha256"],
        @"projects_root_device_id" : evidence[@"projects_root_device_id"],
        @"projects_root_inode_id" : evidence[@"projects_root_inode_id"],
        @"repository_device_id" : evidence[@"repository_device_id"],
        @"repository_inode_id" : evidence[@"repository_inode_id"],
        @"git_device_id" : evidence[@"git_device_id"],
        @"git_inode_id" : evidence[@"git_inode_id"],
      };
      NSString *authorityDigest =
          DSHAuthorityDigestWithoutFingerprint(authorityBase);
      NSDictionary *fingerprintInput = DSHLegacyFingerprintInput(
          record, authorityBase, authorityDigest);
      NSString *rootFingerprint =
          DSHWorkspaceRootFingerprintSHA256(fingerprintInput, nil);
      if (authorityDigest == nil || rootFingerprint == nil) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        return nil;
      }
      NSMutableDictionary *authority = [authorityBase mutableCopy];
      authority[@"root_fingerprint_sha256"] = rootFingerprint;
      return [self commitInternalWorkspaceRecord:record
                                  authorityRecord:authority
                              verifiedCapabilities:capabilities
                                         operation:@"bootstrap_legacy"
                                       operationId:operationId
                          expectedCurrentRevision:nil error:error];
    }
  } @catch (__unused NSException *exception) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
    return nil;
  }
}

- (nullable NSString *)legacyProjectIdForWorkspaceId:(NSString *)workspaceId
                              expectedBindingRevision:(NSUInteger)revision
                                               error:(NSError **)error {
  @try {
    @synchronized(DSHLocalWorkspaceAccess.class) {
      if (!DSHCanonicalUUID(workspaceId) || revision == 0 ||
          revision > DSHWorkspaceMaxSafeInteger) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorInvalid);
        return nil;
      }
      __attribute__((objc_precise_lifetime))
      DSHLocalWorkspaceAuthorityLock *lock = [self acquireAuthorityLock:error];
      if (lock == nil || ![self ensurePrivateLayoutLocked:error]) return nil;
      NSDictionary *registry = [self loadRegistry:error digest:nil];
      if (registry == nil) return nil;
      NSDictionary *record = [self recordInRegistry:registry
                                         workspaceId:workspaceId];
      if (record == nil) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorNotFound);
        return nil;
      }
      if (![record[@"binding_revision"] isEqual:@(revision)]) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorRevisionStale);
        return nil;
      }
      if (![record[@"origin"] isEqual:@"legacy_app_owned"] ||
          ![record[@"root_locator_kind"] isEqual:@"legacy_app_owned"]) {
        return nil;
      }
      NSString *projectId = record[@"legacy_project_id"];
      if (!DSHCanonicalUUID(projectId)) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorConflict);
        return nil;
      }
      NSDictionary *authority = [self loadAuthorityForRecord:record error:error];
      if (authority == nil) return nil;

      NSDictionary *evidence = nil;
      NSError *resolverError = nil;
      BOOL resolved = NO;
      @try {
        resolved = self.legacyResolver(projectId, &evidence, &resolverError);
      } @catch (__unused NSException *exception) {
        resolved = NO;
      }
      if (!resolved || evidence == nil) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
        return nil;
      }
      if (!DSHValidLegacyEvidence(evidence, projectId)) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorConflict);
        return nil;
      }
      NSSet<NSString *> *recordedCapabilities =
          [NSSet setWithArray:authority[@"capabilities"]];
      BOOL evidenceMatches =
          [evidence[@"display_name"] isEqual:record[@"display_name"]] &&
          [evidence[@"metadata_sha256"]
              isEqual:authority[@"root_identity_sha256"]] &&
          [evidence[@"capabilities"] isEqual:recordedCapabilities] &&
          DSHLegacyPhysicalIdentityMatchesAuthority(evidence, authority);
      if (!evidenceMatches) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorRootChanged);
        return nil;
      }
      return [projectId copy];
    }
  } @catch (__unused NSException *exception) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
    return nil;
  }
}

- (nullable NSDictionary *)createRishOwnedWorkspaceWithDisplayName:
    (NSString *)displayName
                                                    operationId:
                                                        (NSString *)operationId
                                                          error:(NSError **)error {
  @try {
    @synchronized(DSHLocalWorkspaceAccess.class) {
      if (!DSHCanonicalDisplayName(displayName) ||
          !DSHCanonicalUUID(operationId)) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorInvalid);
        return nil;
      }
      NSString *requestSHA256 = DSHCreateRequestSHA256(displayName);
      if (!DSHCanonicalSHA256(requestSHA256)) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        return nil;
      }
      __attribute__((objc_precise_lifetime))
      DSHLocalWorkspaceAuthorityLock *lock = [self acquireAuthorityLock:error];
      if (lock == nil) return nil;
      if (![self ensurePrivateLayoutLocked:error]) return nil;

      NSDictionary *pending = [self loadJournalIfPresent:error];
      if (pending == nil) return nil;
      if (pending.count > 0) {
        if (![pending[@"operation_id"] isEqual:operationId] ||
            ![pending[@"operation"] isEqual:@"create"]) {
          DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorBusy);
          return nil;
        }
        if (![pending[@"display_name"] isEqual:displayName] ||
            ![pending[@"request_sha256"] isEqual:requestSHA256]) {
          DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorConflict);
          return nil;
        }
        if (![self recoverJournal:error]) return nil;
      }

      NSMutableArray *receipts = [self loadReceipts:error];
      if (receipts == nil ||
          ![self pruneReceipts:receipts write:YES error:error]) {
        return nil;
      }
      NSDictionary *priorReceipt = [self receiptForOperationId:operationId
                                                     receipts:receipts];
      if (priorReceipt != nil) {
        if (![priorReceipt[@"operation"] isEqual:@"create"]) {
          DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorConflict);
          return nil;
        }
        NSDictionary *registry = [self loadRegistry:error digest:nil];
        NSDictionary *record = registry == nil
            ? nil
            : [self recordInRegistry:registry
                         workspaceId:priorReceipt[@"workspace_id"]];
        if (record == nil) {
          DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
          return nil;
        }
        if (![record[@"display_name"] isEqual:displayName] ||
            (priorReceipt[@"request_sha256"] != nil &&
             ![priorReceipt[@"request_sha256"] isEqual:requestSHA256])) {
          DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorConflict);
          return nil;
        }
        return [self terminalValidatedOwnedDescriptorForRecord:record error:error];
      }

      NSString *registryDigest = nil;
      NSDictionary *registry = [self loadRegistry:error digest:&registryDigest];
      if (registry == nil) return nil;
      if ([registry[@"generation"] unsignedLongLongValue] >=
          DSHWorkspaceMaxSafeInteger) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        return nil;
      }
      // Capacity is a mutation preflight.  Reject before creating the
      // Files-visible container, allocating a UUID, or writing a create
      // journal so a full registry cannot strand an orphaned destination.
      if ([registry[@"records"] count] >= DSHWorkspaceRegistryMaxRecords) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorBusy);
        return nil;
      }
      for (NSDictionary *published in registry[@"records"]) {
        if ([self loadAuthorityForRecord:published error:error] == nil) {
          return nil;
        }
      }
      if (![self ensureOwnedDocumentsLayout:error]) return nil;
      NSString *workspaceId = self.UUIDGenerator();
      NSString *timestamp = DSHCanonicalTimestampForDate(self.clock());
      if (!DSHCanonicalUUID(workspaceId) || timestamp == nil ||
          [self recordInRegistry:registry workspaceId:workspaceId] != nil) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        return nil;
      }
      NSString *directoryName =
          [self allocateOwnedDirectoryNameForDisplayName:displayName
                                                 registry:registry
                                                    error:error];
      if (directoryName == nil) return nil;
      NSString *stagingName =
          [NSString stringWithFormat:@".rish-staging-%@", operationId];
      if (!DSHInternalComponent(stagingName)) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        return nil;
      }
      NSURL *container = [self ownedWorkspacesRootURL];
      NSURL *staging = [container URLByAppendingPathComponent:stagingName
                                                   isDirectory:YES];
      NSURL *destination = [container URLByAppendingPathComponent:directoryName
                                                        isDirectory:YES];
      struct stat state = {};
      if (lstat(staging.fileSystemRepresentation, &state) == 0 ||
          lstat(destination.fileSystemRepresentation, &state) == 0) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorConflict);
        return nil;
      }
      if (errno != ENOENT) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        return nil;
      }
      NSDictionary *record = @{
        @"schema_version" : @1,
        @"workspace_id" : workspaceId,
        @"display_name" : displayName,
        @"origin" : @"rish_created",
        @"root_locator_kind" : @"documents_owned",
        @"location_class" : @"rish_owned",
        @"owned_directory_name" : directoryName,
        @"legacy_project_id" : NSNull.null,
        @"binding_revision" : @1,
        @"created_at" : timestamp,
        @"last_opened_at" : timestamp,
      };
      NSMutableDictionary *journal = [@{
        @"schema_version" : @1,
        @"operation_id" : operationId,
        @"workspace_id" : workspaceId,
        @"operation" : @"create",
        @"phase" : @"prepared",
        @"binding_revision" : @1,
        @"previous_registry_generation" : registry[@"generation"],
        @"previous_registry_sha256" : registryDigest,
        @"authority_sha256" : NSNull.null,
        @"record_sha256" : NSNull.null,
        @"staging_name" : stagingName,
        @"destination_name" : directoryName,
        @"display_name" : displayName,
        @"request_sha256" : requestSHA256,
        @"staging_device_id" : NSNull.null,
        @"staging_inode_id" : NSNull.null,
        @"staging_uid" : NSNull.null,
        @"staging_gid" : NSNull.null,
        @"destination_device_id" : NSNull.null,
        @"destination_inode_id" : NSNull.null,
        @"destination_uid" : NSNull.null,
        @"destination_gid" : NSNull.null,
        @"legacy_project_id" : NSNull.null,
        @"clearance_receipt_id" : NSNull.null,
        @"confirmation_id" : NSNull.null,
        @"created_at" : timestamp,
        @"last_opened_at" : timestamp,
        @"updated_at" : timestamp,
      } mutableCopy];
      if (![self writeProtectedObject:journal
                                toURL:self.journalURL
                             maxBytes:DSHWorkspaceAuthorityMaxBytes
                                error:error]) {
        return nil;
      }
      if (self.faultHook != nil && self.faultHook(@"after_journal_prepared")) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        return nil;
      }
      if (mkdir(staging.fileSystemRepresentation, 0700) != 0 ||
          ![self fsyncDirectoryURL:staging stage:nil error:error] ||
          ![self fsyncDirectoryURL:container stage:nil error:error]) {
        if (error != nil && *error == nil) {
          DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        }
        return nil;
      }
      struct stat stagedState = {};
      if (lstat(staging.fileSystemRepresentation, &stagedState) != 0 ||
          !S_ISDIR(stagedState.st_mode) || S_ISLNK(stagedState.st_mode) ||
          stagedState.st_nlink < 2) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        return nil;
      }
      // Persist the pre-rename identity before any cleanup can be authorized.
      // If a crash occurs after rename but before the destination fields are
      // written, this identity still proves that the destination is our
      // staging directory rather than an external directory with the same
      // name.
      journal[@"staging_device_id"] =
          DSHUnsignedIntegerString((unsigned long long)stagedState.st_dev);
      journal[@"staging_inode_id"] =
          DSHUnsignedIntegerString((unsigned long long)stagedState.st_ino);
      journal[@"staging_uid"] =
          DSHUnsignedIntegerString((unsigned long long)stagedState.st_uid);
      journal[@"staging_gid"] =
          DSHUnsignedIntegerString((unsigned long long)stagedState.st_gid);
      journal[@"updated_at"] = DSHCanonicalTimestampForDate(self.clock());
      if (![self writeProtectedObject:journal
                                toURL:self.journalURL
                             maxBytes:DSHWorkspaceAuthorityMaxBytes
                                error:error]) {
        return nil;
      }
      if (self.faultHook != nil &&
          self.faultHook(@"create_after_staging_fsync")) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        return nil;
      }
      int parentDescriptor =
          open(container.fileSystemRepresentation,
               O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
      int renameResult = parentDescriptor < 0
          ? -1
          : renameatx_np(parentDescriptor, stagingName.UTF8String,
                        parentDescriptor, directoryName.UTF8String,
                        RENAME_EXCL);
      int renameErrno = errno;
      if (parentDescriptor >= 0) close(parentDescriptor);
      if (renameResult != 0) {
        errno = renameErrno;
        DSHSetWorkspaceError(error,
                             errno == EEXIST
                                 ? DSHLocalWorkspaceAccessErrorConflict
                                 : DSHLocalWorkspaceAccessErrorPersistence);
        return nil;
      }
      if (![self fsyncDirectoryURL:container
                             stage:@"create_after_destination_rename"
                             error:error]) {
        return nil;
      }
      struct stat destinationState = {};
      if (lstat(destination.fileSystemRepresentation, &destinationState) != 0 ||
          !DSHSameNode(stagedState, destinationState)) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
        return nil;
      }
      journal[@"destination_device_id"] =
          DSHUnsignedIntegerString((unsigned long long)destinationState.st_dev);
      journal[@"destination_inode_id"] =
          DSHUnsignedIntegerString((unsigned long long)destinationState.st_ino);
      journal[@"destination_uid"] =
          DSHUnsignedIntegerString((unsigned long long)destinationState.st_uid);
      journal[@"destination_gid"] =
          DSHUnsignedIntegerString((unsigned long long)destinationState.st_gid);
      journal[@"updated_at"] = DSHCanonicalTimestampForDate(self.clock());
      if (![self writeProtectedObject:journal
                                toURL:self.journalURL
                             maxBytes:DSHWorkspaceAuthorityMaxBytes
                                error:error]) {
        return nil;
      }
      NSDictionary *authorityBase = @{
        @"schema_version" : @1,
        @"workspace_id" : workspaceId,
        @"binding_revision" : @1,
        @"device_id" : [NSString stringWithFormat:@"%llu",
                        (unsigned long long)destinationState.st_dev],
        @"inode_id" : [NSString stringWithFormat:@"%llu",
                        (unsigned long long)destinationState.st_ino],
        @"directory_name_sha256" :
            DSHSHA256([directoryName dataUsingEncoding:NSUTF8StringEncoding]),
        @"recorded_at" : timestamp,
      };
      NSString *authorityDigest =
          DSHAuthorityDigestWithoutFingerprint(authorityBase);
      NSDictionary *fingerprintInput = DSHDocumentsOwnedFingerprintInput(
          record, authorityBase, authorityDigest);
      NSString *rootFingerprint =
          DSHWorkspaceRootFingerprintSHA256(fingerprintInput, nil);
      if (authorityDigest == nil || rootFingerprint == nil) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        return nil;
      }
      NSMutableDictionary *authority = [authorityBase mutableCopy];
      authority[@"root_fingerprint_sha256"] = rootFingerprint;
      NSURL *authorityURL = [self authorityURLForKind:@"owned"
                                           workspaceId:workspaceId
                                              revision:@1];
      if (![self writeProtectedObject:authority
                                toURL:authorityURL
                             maxBytes:DSHWorkspaceAuthorityMaxBytes
                                error:error]) {
        return nil;
      }
      if (self.faultHook != nil &&
          self.faultHook(@"after_authority_write_before_journal")) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        return nil;
      }
      journal[@"phase"] = @"authority_ready";
      journal[@"authority_sha256"] = DSHSHA256(DSHCanonicalJSON(authority));
      journal[@"record_sha256"] = DSHSHA256(DSHCanonicalJSON(record));
      journal[@"updated_at"] = DSHCanonicalTimestampForDate(self.clock());
      if (![self writeProtectedObject:journal
                                toURL:self.journalURL
                             maxBytes:DSHWorkspaceAuthorityMaxBytes
                                error:error]) {
        return nil;
      }
      if (self.faultHook != nil && self.faultHook(@"after_authority_ready")) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        return nil;
      }
      if (self.faultHook != nil &&
          self.faultHook(@"before_create_registry_publication")) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        return nil;
      }
      NSString *currentDigest = nil;
      NSDictionary *currentRegistry = [self loadRegistry:error
                                                   digest:&currentDigest];
      if (currentRegistry == nil) return nil;
      if (![currentRegistry[@"generation"] isEqual:registry[@"generation"]] ||
          ![currentDigest isEqual:registryDigest]) {
        NSError *cleanupError = nil;
        if (![self removeCreateArtifactNamed:directoryName
                                      journal:journal
                                        error:&cleanupError] ||
            ![self removeProtectedURL:authorityURL error:&cleanupError] ||
            ![self removeProtectedURL:self.journalURL error:&cleanupError]) {
          DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
          return nil;
        }
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorConflict);
        return nil;
      }
      if (![self writeRegistryFromPrevious:currentRegistry
                                    record:record
                                     error:error]) {
        return nil;
      }
      if (self.faultHook != nil &&
          self.faultHook(@"after_create_registry_publication_before_journal")) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        return nil;
      }
      journal[@"phase"] = @"registry_committed";
      journal[@"updated_at"] = DSHCanonicalTimestampForDate(self.clock());
      if (![self writeProtectedObject:journal
                                toURL:self.journalURL
                             maxBytes:DSHWorkspaceAuthorityMaxBytes
                                error:error]) {
        return nil;
      }
      if (self.faultHook != nil &&
          self.faultHook(@"after_create_registry_publication")) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        return nil;
      }
      if (![self finishCommittedJournal:journal error:error]) return nil;
      if (self.faultHook != nil &&
          self.faultHook(@"before_create_terminal_validation")) {
        DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        return nil;
      }
      NSDictionary *terminalRegistry = [self loadRegistry:error digest:nil];
      NSDictionary *terminalRecord = terminalRegistry == nil
          ? nil
          : [self recordInRegistry:terminalRegistry workspaceId:workspaceId];
      if (terminalRecord == nil || ![terminalRecord isEqual:record]) {
        if (error != nil && *error == nil) {
          DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorPersistence);
        }
        return nil;
      }
      return [self terminalValidatedOwnedDescriptorForRecord:terminalRecord
                                                        error:error];
    }
  } @catch (__unused NSException *exception) {
    DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
    return nil;
  }
}

- (nullable NSDictionary *)forgetWorkspaceId:(NSString *)workspaceId
                       expectedBindingRevision:(NSNumber *)revision
                                     operationId:(NSString *)operationId
                               clearanceReceiptId:(NSString *)clearanceReceiptId
                                            error:(NSError **)error {
  (void)workspaceId;
  (void)revision;
  (void)operationId;
  (void)clearanceReceiptId;
  DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
  return nil;
}

- (nullable NSDictionary *)prepareDeleteOwnedContentForWorkspaceId:
    (NSString *)workspaceId
                       expectedBindingRevision:(NSNumber *)revision
                           clearanceReceiptId:(NSString *)clearanceReceiptId
                                        error:(NSError **)error {
  (void)workspaceId;
  (void)revision;
  (void)clearanceReceiptId;
  DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
  return nil;
}

- (nullable NSDictionary *)deleteOwnedContentForWorkspaceId:
    (NSString *)workspaceId
                       expectedBindingRevision:(NSNumber *)revision
                                     operationId:(NSString *)operationId
                               clearanceReceiptId:(NSString *)clearanceReceiptId
                                  confirmationId:(NSString *)confirmationId
                                            error:(NSError **)error {
  (void)workspaceId;
  (void)revision;
  (void)operationId;
  (void)clearanceReceiptId;
  (void)confirmationId;
  DSHSetWorkspaceError(error, DSHLocalWorkspaceAccessErrorUnavailable);
  return nil;
}

@end
