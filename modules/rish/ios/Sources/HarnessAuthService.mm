#import "HarnessAuthService.h"
#import "ClaudeOfficialSession.h"
#import "DSHGuestRuntimeState.h"
#import "LocalGuestModule.h"

#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#include "rish.h"
#include <limits.h>
#include <stdio.h>

NSString *const DSHHarnessAuthHarnessCodex = @"codex";
NSString *const DSHHarnessAuthHarnessClaudeCode = @"claude-code";

// Both subscriptions run their official CLI in the guest -- Claude's token is
// rejected everywhere but the CLI, and Codex is routed the same way for one
// architecture. The CLIs are native musl binaries downloaded on the host, once,
// to Application Support; the guest installs them from there and reuses them.
static NSString *const DSHCodexCliVersion = @"0.153.4";
static NSString *const DSHCodexCliURL =
    @"https://github.com/openai/codex/releases/download/rust-v0.153.4/"
    @"codex-x86_64-unknown-linux-musl.tar.gz";
static NSString *const DSHCodexCliFile = @"codex-cli.tar.gz";
static NSString *const DSHClaudeCliVersion = @"2.1.276";
static NSString *const DSHClaudeCliURL =
    @"https://downloads.claude.ai/claude-code-releases/2.1.276/linux-x64-musl/claude";
static NSString *const DSHClaudeCliFile = @"claude-cli.bin";
// A download that stops short of this is treated as truncated; the exact size
// is checked after the transfer, not trusted from Content-Length mid-flight.
static unsigned long long const DSHCliMinimumBytes = 1024 * 1024;

static NSString *const DSHHarnessAuthManifestName = @"HarnessAuthAssets";

static NSString *const DSHHarnessAuthKeychainService =
    @"tech.zseven.rish.harness-subscription-auth";
static NSUInteger const DSHHarnessAuthMaxOutputBytes = 64 * 1024;
BOOL DSHCodexChatUsesSubscription(void) {
  static DSHHarnessAuthService *reader;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ reader = [[DSHHarnessAuthService alloc] initWithBundle:NSBundle.mainBundle]; });
  return [[reader codexChatSource] isEqualToString:@"subscription"];
}
static NSString *const DSHCodexChatSourceKeychainAccount = @"codex-chat-source";
static NSString *const DSHClaudeChatSourceKeychainAccount = @"claude-chat-source";
static NSString *const DSHCodexChatSubscription = @"subscription";
static NSString *const DSHCodexChatAPIKey = @"api_key";
static NSString *const DSHCodexOAuthTokenURL = @"https://auth.openai.com/oauth/token";
static NSString *const DSHCodexOAuthClientID = @"app_EMoamEEZ73f0CkXaXp7hrann";


static NSDictionary *DSHAuthRuntime(BOOL available, NSString *version,
                                    NSString *reason) {
  NSMutableDictionary *runtime = [@{
    @"kind": @"official-cli",
    @"available": @(available),
  } mutableCopy];
  if (version.length > 0) runtime[@"version"] = version;
  if (reason.length > 0) runtime[@"reason"] = reason;
  return runtime;
}

static BOOL DSHAuthSupportedHarness(id harnessId) {
  if (![harnessId isKindOfClass:NSString.class]) return NO;
  return [harnessId isEqualToString:DSHHarnessAuthHarnessCodex] ||
         [harnessId isEqualToString:DSHHarnessAuthHarnessClaudeCode];
}

static BOOL DSHAuthSafeRelativeResource(id value) {
  if (![value isKindOfClass:NSString.class]) return NO;
  NSString *resource = value;
  if (resource.length == 0 || resource.length > 256 ||
      [resource hasPrefix:@"/"] || [resource containsString:@"\\"] ||
      [resource containsString:@".."] || [resource containsString:@"\0"]) {
    return NO;
  }
  NSCharacterSet *invalid = [[NSCharacterSet
      characterSetWithCharactersInString:
          @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./"]
      invertedSet];
  return [resource rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

static BOOL DSHAuthSHA256(id value) {
  if (![value isKindOfClass:NSString.class]) return NO;
  NSString *digest = value;
  if (digest.length != CC_SHA256_DIGEST_LENGTH * 2) return NO;
  NSCharacterSet *nonHex = [[NSCharacterSet
      characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
  return [digest rangeOfCharacterFromSet:nonHex].location == NSNotFound;
}

static NSString *DSHAuthSHA256File(NSURL *url) {
  NSInputStream *stream = [NSInputStream inputStreamWithURL:url];
  if (stream == nil) return nil;
  [stream open];
  CC_SHA256_CTX context;
  CC_SHA256_Init(&context);
  uint8_t buffer[64 * 1024];
  NSUInteger totalBytes = 0;
  BOOL failed = NO;
  while (stream.hasBytesAvailable) {
    NSInteger count = [stream read:buffer maxLength:sizeof(buffer)];
    if (count < 0) {
      failed = YES;
      break;
    }
    if (count == 0) break;
    CC_SHA256_Update(&context, buffer, (CC_LONG)count);
    totalBytes += (NSUInteger)count;
  }
  [stream close];
  if (failed || totalBytes == 0) return nil;
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256_Final(digest, &context);
  NSMutableString *hex = [NSMutableString
      stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
  for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index += 1) {
    [hex appendFormat:@"%02x", digest[index]];
  }
  return hex;
}

static NSDictionary *DSHAuthManifestForBundle(NSBundle *bundle) {
  NSURL *manifestURL = [bundle URLForResource:DSHHarnessAuthManifestName
                                  withExtension:@"json"];
  if (manifestURL == nil) {
    manifestURL = [bundle URLForResource:DSHHarnessAuthManifestName
                             withExtension:@"json"
                              subdirectory:@"HarnessAuth"];
  }
  NSData *data = manifestURL == nil
      ? nil
      : [NSData dataWithContentsOfURL:manifestURL options:0 error:nil];
  if (data == nil || data.length == 0 || data.length > 32 * 1024) return nil;
  NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:data
                                                              options:0
                                                                error:nil];
  if (![manifest isKindOfClass:NSDictionary.class] ||
      ![manifest[@"schema_version"] isEqual:@1] ||
      ![manifest[@"harnesses"] isKindOfClass:NSDictionary.class]) {
    return nil;
  }
  NSDictionary *harnesses = manifest[@"harnesses"];
  for (NSString *harnessId in @[DSHHarnessAuthHarnessCodex, DSHHarnessAuthHarnessClaudeCode]) {
    NSDictionary *entry = harnesses[harnessId];
    if (entry == nil && [harnessId isEqual:DSHHarnessAuthHarnessClaudeCode]) continue;
    if (![entry isKindOfClass:NSDictionary.class] ||
        entry.count != 5 ||
        ![entry[@"version"] isKindOfClass:NSString.class] ||
        [entry[@"version"] length] == 0 || [entry[@"version"] length] > 64 ||
        !DSHAuthSafeRelativeResource(entry[@"kernel_resource"]) ||
        !DSHAuthSafeRelativeResource(entry[@"initrd_resource"]) ||
        !DSHAuthSHA256(entry[@"kernel_sha256"]) ||
        !DSHAuthSHA256(entry[@"initrd_sha256"])) {
      return nil;
    }
  }
  return manifest;
}

static NSDictionary *DSHAuthAssetInfo(NSBundle *bundle, NSString *harnessId,
                                      NSDictionary *manifest) {
  NSDictionary *entry = manifest[@"harnesses"][harnessId];
  NSString *resource = entry[@"cli_resource"];
  NSURL *root = bundle.resourceURL;
  NSURL *url = resource.length > 0 ? [root URLByAppendingPathComponent:resource] : nil;
  NSString *rootPath = root.path.stringByStandardizingPath;
  NSString *path = url.path.stringByStandardizingPath;
  BOOL insideBundle = [path hasPrefix:[rootPath stringByAppendingString:@"/"]];
  BOOL regular = NO;
  NSDictionary *attributes = nil;
  if (insideBundle) {
    attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path
                                                                    error:nil];
    regular = [attributes[NSFileType] isEqual:NSFileTypeRegular];
  }
  NSString *digest = regular ? DSHAuthSHA256File(url) : nil;
  BOOL available = resource.length == 0 || (regular &&
      [digest isEqualToString:entry[@"sha256"]]);
  NSString *reason = nil;
  if (DSHAuthSupportedHarness(harnessId) && available) {
    for (NSString *key in @[ @"kernel_resource", @"initrd_resource" ]) {
      NSString *assetResource = entry[key];
      NSURL *assetURL = [root URLByAppendingPathComponent:assetResource];
      NSDictionary *attrs = [[NSFileManager defaultManager]
          attributesOfItemAtPath:assetURL.path error:nil];
      if (![attrs[NSFileType] isEqual:NSFileTypeRegular] ||
          ![DSHAuthSHA256File(assetURL) isEqualToString:
              entry[[key isEqualToString:@"kernel_resource"]
                  ? @"kernel_sha256" : @"initrd_sha256"]]) {
        available = NO;
        reason = [key isEqualToString:@"kernel_resource"]
            ? @"official-cli-kernel-asset-invalid"
            : @"official-cli-initrd-asset-invalid";
        break;
      }
    }
  }
  if (resource.length > 0 && !regular) reason = @"official-cli-asset-missing";
  else if (reason == nil && !available) reason = @"official-cli-asset-integrity-failed";
  return @{
    @"available": @(available),
    @"version": entry[@"version"],
    @"reason": reason ?: [NSNull null],
    @"cli_url": url ?: [NSNull null],
    @"kernel_url": [root URLByAppendingPathComponent:entry[@"kernel_resource"] ?: @""],
    @"initrd_url": [root URLByAppendingPathComponent:entry[@"initrd_resource"] ?: @""],
  };
}

static NSMutableDictionary *DSHAuthBaseStatus(NSString *harnessId,
                                                NSDictionary *runtime) {
  return [@{
    @"schema_version": @1,
    @"harness_id": harnessId,
    @"runtime": runtime,
    @"status": @"unavailable",
    @"auth_method": @"none",
  } mutableCopy];
}

static NSData *DSHAuthStoredCredential(NSString *harnessId, OSStatus *statusOut);
static BOOL DSHAuthStoreCredential(NSString *harnessId, NSData *data);

static NSMutableDictionary *DSHCodexSourceQuery(void) {
  return [@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService:DSHHarnessAuthKeychainService,
            (__bridge id)kSecAttrAccount:DSHCodexChatSourceKeychainAccount,
            (__bridge id)kSecAttrSynchronizable:@NO} mutableCopy];
}

static NSMutableDictionary *DSHClaudeSourceQuery(void) {
  return [@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService:DSHHarnessAuthKeychainService,
            (__bridge id)kSecAttrAccount:DSHClaudeChatSourceKeychainAccount,
            (__bridge id)kSecAttrSynchronizable:@NO} mutableCopy];
}

static NSString *DSHCodexJWTStringPart(NSString *jwt, NSUInteger index) {
  if (![jwt isKindOfClass:NSString.class]) return nil;
  NSArray *parts = [jwt componentsSeparatedByString:@"."];
  if (parts.count != 3 || index >= parts.count) return nil;
  NSString *part = parts[index];
  NSMutableString *base64 = [part mutableCopy];
  while (base64.length % 4) [base64 appendString:@"="];
  [base64 replaceOccurrencesOfString:@"-" withString:@"+" options:0 range:NSMakeRange(0, base64.length)];
  [base64 replaceOccurrencesOfString:@"_" withString:@"/" options:0 range:NSMakeRange(0, base64.length)];
  NSData *data = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
  return data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

static BOOL DSHCodexValidAuthJSON(NSDictionary *json) {
  NSDictionary *tokens = [json isKindOfClass:NSDictionary.class] && [json[@"tokens"] isKindOfClass:NSDictionary.class] ? json[@"tokens"] : nil;
  NSString *access = [tokens[@"access_token"] isKindOfClass:NSString.class] ? tokens[@"access_token"] : nil;
  NSString *refresh = [tokens[@"refresh_token"] isKindOfClass:NSString.class] ? tokens[@"refresh_token"] : nil;
  NSCharacterSet *controls = [NSCharacterSet controlCharacterSet];
  return access.length > 0 && refresh.length > 0 && access.length <= 1024 * 1024 && refresh.length <= 1024 * 1024 &&
      [access rangeOfCharacterFromSet:controls].location == NSNotFound && [refresh rangeOfCharacterFromSet:controls].location == NSNotFound;
}

static BOOL DSHAuthSafeOAuthQuery(NSString *query) {
  if (query.length == 0) return YES;
  if (query.length > 2048) return NO;
  NSSet *allowedKeys = [NSSet setWithArray:@[
    @"state", @"code_challenge", @"code_challenge_method", @"client_id",
    @"redirect_uri", @"response_type", @"scope", @"prompt", @"code",
  ]];
  NSSet *tokenKeys = [NSSet setWithArray:@[
    @"access_token", @"refresh_token", @"id_token", @"token",
  ]];
  NSURLComponents *components = [NSURLComponents componentsWithString:
      [NSString stringWithFormat:@"https://auth.invalid/?%@", query]];
  NSArray<NSURLQueryItem *> *items = components.queryItems;
  if (items.count == 0) return NO;
  NSUInteger codeFlags = 0;
  for (NSURLQueryItem *item in items) {
    if ([item.name isEqual:@"code"] && (![item.value isEqual:@"true"] || ++codeFlags > 1)) return NO;
    if (![item.name isKindOfClass:NSString.class] ||
        [tokenKeys containsObject:item.name] ||
        ![allowedKeys containsObject:item.name] ||
        ![item.value isKindOfClass:NSString.class] ||
        item.value.length > 1024 ||
        [item.value rangeOfCharacterFromSet:
            [NSCharacterSet controlCharacterSet]].location != NSNotFound) {
      return NO;
    }
  }
  return YES;
}

static NSString *DSHAuthSafeVerificationURL(id value,
                                             NSString *harnessId) {
  if (![value isKindOfClass:NSString.class]) return nil;
  NSString *candidate = value;
  NSURLComponents *components = [NSURLComponents componentsWithString:candidate];
  NSString *host = components.host.lowercaseString;
  NSString *path = components.path;
  BOOL allowed = [components.scheme.lowercaseString isEqualToString:@"https"] &&
      (components.port == nil || components.port.integerValue == 443) &&
      components.user.length == 0 && components.password.length == 0 &&
      components.fragment.length == 0;
  if ([harnessId isEqualToString:DSHHarnessAuthHarnessCodex]) {
    allowed = allowed && [host isEqualToString:@"auth.openai.com"] &&
        [path isEqualToString:@"/codex/device"] &&
        components.query.length == 0;
  } else if ([harnessId isEqualToString:DSHHarnessAuthHarnessClaudeCode]) {
    BOOL authorizationPath = ([host isEqualToString:@"claude.ai"] && [path isEqual:@"/oauth/authorize"]) ||
        ([host isEqualToString:@"claude.com"] && [path isEqual:@"/cai/oauth/authorize"]);
    allowed = allowed && authorizationPath &&
        DSHAuthSafeOAuthQuery(components.query);
    for (NSURLQueryItem *item in components.queryItems) {
      if ([item.name isEqual:@"code"] && !authorizationPath) allowed = NO;
    }
  } else {
    allowed = NO;
  }
  if (!allowed) return nil;
  NSString *query = components.query.length > 0
      ? [NSString stringWithFormat:@"?%@", components.query] : @"";
  return [NSString stringWithFormat:@"https://%@%@%@", host, path, query];
}

static NSString *DSHAuthSafeUserCode(id value) {
  if (![value isKindOfClass:NSString.class]) return nil;
  NSString *code = [value uppercaseString];
  NSRegularExpression *expression = [NSRegularExpression
      regularExpressionWithPattern:@"^[A-Z0-9]{4,12}(?:-[A-Z0-9]{4,12})?$"
                             options:0 error:nil];
  NSRange range = NSMakeRange(0, code.length);
  return [expression firstMatchInString:code options:0 range:range] != nil
      ? code : nil;
}

static BOOL DSHAuthValidSessionId(id value) {
  return [value isKindOfClass:NSString.class] &&
      [(NSString *)value length] > 0 && [(NSString *)value length] <= 128 &&
      [(NSString *)value rangeOfString:@"\0"].location == NSNotFound;
}

@interface DSHHarnessAuthService () <NSURLSessionTaskDelegate>
@property(nonatomic, strong) NSBundle *bundle;
@property(nonatomic, strong) DSHClaudeOfficialSession *cachedClaudeSession;
@property(nonatomic) BOOL claudeRestorePending;
@property(nonatomic, strong) NSMutableArray *claudeRestoreWaiters;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) dispatch_queue_t workerQueue;
@property(nonatomic, copy) NSString *activeSessionId;
@property(nonatomic, copy) NSString *activeVerificationURL;
@property(nonatomic, copy) NSString *activeUserCode;
@property(nonatomic, copy) NSString *activeErrorCode;
@property(nonatomic, copy) NSString *lastErrorCode;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSUInteger streamGeneration;
@property(nonatomic, strong) NSMutableData *loginOutput;
@property(nonatomic, copy) NSString *activePhase;
@property(nonatomic) BOOL codexRefreshInFlight;
@property(nonatomic, strong) NSMutableArray *codexRefreshWaiters;
// CLI install state, keyed by harness id. Each value is a mutable dictionary
// with phase (idle|downloading|ready|failed), fraction (0..1) and error_code.
// Read under @synchronized(self); surfaced through statusForHarnessId.
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary *> *installState;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSURLSessionDownloadTask *> *installTasks;
- (DSHClaudeOfficialSession *)validatedClaudeSession;
- (void)receiveStreamEvent:(const char *)event length:(size_t)length;
- (void)runCodexLoginForSession:(NSString *)sessionId generation:(NSUInteger)generation;
- (void)finishCodexLoginWithGeneration:(NSUInteger)generation
                              response:(NSDictionary *)response;
- (void)performCodexRefreshWithGeneration:(NSUInteger)generation;
- (void)completeCodexRefresh:(NSDictionary *)credential errorCode:(NSString *)errorCode;
@end

@implementation DSHHarnessAuthService

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response
    newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
  (void)session; (void)task; (void)response; (void)request;
  completionHandler(nil);
}

- (instancetype)initWithBundle:(NSBundle *)bundle {
  self = [super init];
  if (self != nil) {
    _bundle = bundle ?: NSBundle.mainBundle;
    _queue = dispatch_queue_create("tech.zseven.rish.harness-auth",
                                   DISPATCH_QUEUE_SERIAL);
    _workerQueue = dispatch_queue_create("tech.zseven.rish.harness-auth-worker",
                                         dispatch_queue_attr_make_with_qos_class(
                                             DISPATCH_QUEUE_SERIAL,
                                             QOS_CLASS_USER_INITIATED, 0));
    _codexRefreshWaiters = [NSMutableArray array];
    _installState = [NSMutableDictionary dictionary];
    _installTasks = [NSMutableDictionary dictionary];
  }
  return self;
}

- (NSString *)claudeChatSource {
  @synchronized (self) {
    NSMutableDictionary *query = DSHClaudeSourceQuery();
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = nil;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    NSData *data = status == errSecSuccess && result != nil ? CFBridgingRelease(result) : nil;
    NSString *stored = [data isKindOfClass:NSData.class] ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    if ([stored isEqualToString:@"api_key"]) return stored;
    if ([stored isEqualToString:@"subscription"]) return stored;
    if (status != errSecItemNotFound) return @"unavailable";
    // Preserve the subscription route only when the official guest has a
    // saved-session hint. Fresh/manual installs remain API-key based until
    // the user explicitly selects subscription.
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *directory = [support URLByAppendingPathComponent:@"official-claude" isDirectory:YES];
    BOOL saved = [NSFileManager.defaultManager fileExistsAtPath:[directory URLByAppendingPathComponent:@"verified-session.hint"].path] &&
        [NSFileManager.defaultManager fileExistsAtPath:[directory URLByAppendingPathComponent:@"guest-home.img"].path];
    return saved ? @"subscription" : @"api_key";
  }
}

- (BOOL)selectClaudeChatSource:(NSString *)source error:(NSError **)error {
  if (![source isEqualToString:@"subscription"] && ![source isEqualToString:@"api_key"]) {
    if (error) *error = [NSError errorWithDomain:DSHHarnessAuthKeychainService code:EINVAL userInfo:@{NSLocalizedDescriptionKey:@"Invalid Claude chat source"}];
    return NO;
  }
  NSData *data = [source dataUsingEncoding:NSUTF8StringEncoding];
  OSStatus status;
  NSString *previous = nil;
  @synchronized (self) {
    NSMutableDictionary *read = DSHClaudeSourceQuery();
    read[(__bridge id)kSecReturnData] = @YES;
    CFTypeRef result = nil;
    OSStatus readStatus = SecItemCopyMatching((__bridge CFDictionaryRef)read, &result);
    NSData *oldData = readStatus == errSecSuccess && result != nil ? CFBridgingRelease(result) : nil;
    previous = [oldData isKindOfClass:NSData.class] ? [[NSString alloc] initWithData:oldData encoding:NSUTF8StringEncoding] : nil;
    NSMutableDictionary *query = DSHClaudeSourceQuery();
    NSDictionary *attrs = @{(__bridge id)kSecValueData:data, (__bridge id)kSecAttrAccessible:(__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly};
    status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attrs);
    if (status == errSecItemNotFound) {
      query[(__bridge id)kSecValueData] = data;
      query[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
      status = SecItemAdd((__bridge CFDictionaryRef)query, nil);
    }
  }
  if (status != errSecSuccess) {
    if (error) *error = [NSError errorWithDomain:DSHHarnessAuthKeychainService code:status userInfo:@{NSLocalizedDescriptionKey:@"Unable to save Claude chat source"}];
    return NO;
  }
  void (^changed)(void) = nil;
  @synchronized (self) { changed = [self.onClaudeChatCredentialChanged copy]; }
  if ([previous isEqualToString:source]) changed = nil;
  if (changed) changed();
  return YES;
}

- (DSHClaudeOfficialSession *)claudeOfficialSession {
  return [self validatedClaudeSession];
}

- (NSString *)codexChatSource {
  @synchronized (self) {
    NSMutableDictionary *query = DSHCodexSourceQuery();
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = nil;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    NSData *storedData = status == errSecSuccess && result != nil
        ? CFBridgingRelease(result) : nil;
    NSString *stored = [storedData isKindOfClass:NSData.class]
        ? [[NSString alloc] initWithData:storedData encoding:NSUTF8StringEncoding] : nil;
    if ([stored isEqualToString:DSHCodexChatAPIKey]) return DSHCodexChatAPIKey;
    if ([stored isEqualToString:DSHCodexChatSubscription]) return stored;
    if (status != errSecItemNotFound) return @"unavailable";
    OSStatus authStatus = errSecSuccess;
    NSData *data = DSHAuthStoredCredential(DSHHarnessAuthHarnessCodex, &authStatus);
    NSDictionary *json = data == nil ? nil : [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [DSHHarnessAuthService codexChatCredentialFromAuthJSON:json] != nil ? DSHCodexChatSubscription : DSHCodexChatAPIKey;
  }
}

- (BOOL)selectCodexChatSource:(NSString *)source error:(NSError **)error {
  if (![source isEqualToString:DSHCodexChatSubscription] && ![source isEqualToString:DSHCodexChatAPIKey]) {
    if (error) *error = [NSError errorWithDomain:DSHHarnessAuthKeychainService code:EINVAL userInfo:@{NSLocalizedDescriptionKey:@"Invalid Codex chat source"}];
    return NO;
  }
  NSData *data = [source dataUsingEncoding:NSUTF8StringEncoding];
  OSStatus status;
  NSString *previous;
  @synchronized (self) {
    NSMutableDictionary *read = DSHCodexSourceQuery();
    read[(__bridge id)kSecReturnData] = @YES;
    CFTypeRef result = nil;
    OSStatus readStatus = SecItemCopyMatching((__bridge CFDictionaryRef)read, &result);
    NSData *oldData = readStatus == errSecSuccess && result != nil ? CFBridgingRelease(result) : nil;
    previous = [oldData isKindOfClass:NSData.class] ? [[NSString alloc] initWithData:oldData encoding:NSUTF8StringEncoding] : nil;
    NSMutableDictionary *query = DSHCodexSourceQuery();
    NSDictionary *attrs = @{(__bridge id)kSecValueData:data, (__bridge id)kSecAttrAccessible:(__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly};
    status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attrs);
    if (status == errSecItemNotFound) {
      query[(__bridge id)kSecValueData] = data;
      query[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
      status = SecItemAdd((__bridge CFDictionaryRef)query, nil);
    }
  }
  if (status != errSecSuccess) {
    if (error) *error = [NSError errorWithDomain:DSHHarnessAuthKeychainService code:status userInfo:@{NSLocalizedDescriptionKey:@"Unable to save Codex chat source"}];
    return NO;
  }
  void (^changed)(void);
  @synchronized (self) { changed = [self.onCodexChatCredentialChanged copy]; }
  if ([previous isEqualToString:source]) changed = nil;
  if (changed) changed();
  return YES;
}

+ (NSDictionary *)codexChatCredentialFromAuthJSON:(NSDictionary *)json {
  if (!DSHCodexValidAuthJSON(json)) return nil;
  NSDictionary *tokens = json[@"tokens"];
  NSString *account = [tokens[@"account_id"] isKindOfClass:NSString.class] ? tokens[@"account_id"] : ([json[@"account_id"] isKindOfClass:NSString.class] ? json[@"account_id"] : nil);
  if (account.length == 0) {
    NSDictionary *claims = nil;
    NSString *payload = DSHCodexJWTStringPart(tokens[@"id_token"], 1);
    NSData *data = [payload dataUsingEncoding:NSUTF8StringEncoding];
    id object = data == nil ? nil : [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([object isKindOfClass:NSDictionary.class]) claims = object;
    NSDictionary *authClaims = [claims[@"https://api.openai.com/auth"] isKindOfClass:NSDictionary.class] ? claims[@"https://api.openai.com/auth"] : nil;
    account = [authClaims[@"chatgpt_account_id"] isKindOfClass:NSString.class] ? authClaims[@"chatgpt_account_id"] : nil;
  }
  NSMutableDictionary *credential = [@{ @"access_token":tokens[@"access_token"] } mutableCopy];
  if (account.length == 0) return nil;
  if ([account rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound) return nil;
  credential[@"account_id"] = account;
  return credential;
}

+ (BOOL)codexAccessTokenNeedsRefresh:(NSString *)accessToken now:(NSDate *)now {
  NSString *payload = DSHCodexJWTStringPart(accessToken, 1);
  NSData *data = [payload dataUsingEncoding:NSUTF8StringEncoding];
  id object = data == nil ? nil : [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  NSDictionary *claims = [object isKindOfClass:NSDictionary.class] ? object : nil;
  NSNumber *exp = [claims[@"exp"] isKindOfClass:NSNumber.class] ? claims[@"exp"] : nil;
  return exp == nil || exp.doubleValue <= (now ?: [NSDate date]).timeIntervalSince1970 + 60.0;
}

- (DSHClaudeOfficialSession *)validatedClaudeSession {
  @synchronized (self) {
    if (self.cachedClaudeSession != nil) return self.cachedClaudeSession;
    // Claude runs its CLI in the guest, installed from the host download. The
    // session exists only once the shared guest assets, a home disk and the
    // downloaded CLI are all present; until then the card shows the install
    // button (statusForHarnessId supplies the install snapshot).
    NSDictionary *assets = DSHAuthSharedGuestAssets(self.bundle);
    NSURL *cli = [DSHHarnessAuthService installedCliURLForHarness:DSHHarnessAuthHarnessClaudeCode];
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    if (assets == nil || cli == nil || support == nil) return nil;
    self.cachedClaudeSession = [[DSHClaudeOfficialSession alloc]
        initWithKernelURL:assets[@"kernel_url"] initrdURL:assets[@"initrd_url"]
        storageDirectory:[support URLByAppendingPathComponent:@"official-claude" isDirectory:YES]
        version:DSHClaudeCliVersion];
    self.cachedClaudeSession.cliDeliveryURL = cli;
    if (self.cachedClaudeSession.shouldRestoreSavedSession) {
      self.claudeRestorePending = YES;
      [self.cachedClaudeSession refresh:^(__unused NSDictionary *status) {
        NSArray *waiters = nil;
        @synchronized (self) {
          self.claudeRestorePending = NO;
          waiters = [self.claudeRestoreWaiters copy];
          [self.claudeRestoreWaiters removeAllObjects];
        }
        NSDictionary *current = [self statusForHarnessId:@"claude-code"];
        for (void (^waiter)(NSDictionary *) in waiters) [self finishAsync:waiter status:current];
      }];
    }
    return self.cachedClaudeSession;
  }
}

- (void)submitClaudeLoginCode:(NSString *)code session:(NSString *)session
                  completion:(void (^)(NSDictionary *))completion {
  DSHClaudeOfficialSession *runner = [self validatedClaudeSession];
  if (runner != nil) {
    [runner submitCode:code session:session completion:^(NSDictionary *status) {
      if ([status[@"status"] isEqualToString:@"signed_in"]) {
        void (^changed)(void) = nil;
        @synchronized (self) { changed = [self.onClaudeChatCredentialChanged copy]; }
        if (changed) changed();
      }
      if (completion) completion(status);
    }];
  }
  else [self finishAsync:completion status:[self statusForHarnessId:@"claude-code"]];
}

- (void)readStatusForHarnessId:(NSString *)harnessId completion:(void (^)(NSDictionary *))completion {
  if ([harnessId isEqual:@"claude-code"]) {
    [self validatedClaudeSession];
    @synchronized (self) {
      if (self.claudeRestorePending) {
        if (self.claudeRestoreWaiters == nil) self.claudeRestoreWaiters = [NSMutableArray array];
        if (completion) [self.claudeRestoreWaiters addObject:[completion copy]];
        return;
      }
    }
  }
  [self finishAsync:completion status:[self statusForHarnessId:harnessId]];
}

#pragma mark CLI install (host-side download)

/// The URL, filename and pinned version for a harness's CLI, or nil for an
/// unknown harness.
+ (NSDictionary *)cliDescriptorForHarness:(NSString *)harnessId {
  if ([harnessId isEqualToString:DSHHarnessAuthHarnessCodex]) {
    return @{ @"url": DSHCodexCliURL, @"file": DSHCodexCliFile, @"version": DSHCodexCliVersion };
  }
  if ([harnessId isEqualToString:DSHHarnessAuthHarnessClaudeCode]) {
    return @{ @"url": DSHClaudeCliURL, @"file": DSHClaudeCliFile, @"version": DSHClaudeCliVersion };
  }
  return nil;
}

/// Application Support/harness-cli, created on demand, excluded from backup.
+ (NSURL *)cliDirectory {
  NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                        inDomains:NSUserDomainMask].firstObject;
  if (support == nil) return nil;
  NSURL *directory = [support URLByAppendingPathComponent:@"harness-cli" isDirectory:YES];
  if (![NSFileManager.defaultManager createDirectoryAtURL:directory
                              withIntermediateDirectories:YES
                                               attributes:@{NSFileProtectionKey: NSFileProtectionComplete}
                                                    error:nil]) {
    return nil;
  }
  [directory setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
  return directory;
}

/// The on-disk CLI download for a harness, or nil if it is not present at its
/// full expected size. A short file is a partial transfer and never counted.
+ (NSURL *)installedCliURLForHarness:(NSString *)harnessId {
  NSDictionary *descriptor = [self cliDescriptorForHarness:harnessId];
  NSURL *directory = [self cliDirectory];
  if (descriptor == nil || directory == nil) return nil;
  NSURL *url = [directory URLByAppendingPathComponent:descriptor[@"file"]];
  NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
  if (![attributes[NSFileType] isEqual:NSFileTypeRegular]) return nil;
  if ([attributes[NSFileSize] unsignedLongLongValue] < DSHCliMinimumBytes) return nil;
  return url;
}

- (NSDictionary *)installSnapshotForHarness:(NSString *)harnessId {
  BOOL present = [DSHHarnessAuthService installedCliURLForHarness:harnessId] != nil;
  @synchronized (self) {
    NSDictionary *state = self.installState[harnessId];
    NSString *phase = present ? @"ready"
        : ([state[@"phase"] isKindOfClass:NSString.class] ? state[@"phase"] : @"idle");
    NSMutableDictionary *snapshot = [@{ @"phase": phase } mutableCopy];
    if ([state[@"fraction"] isKindOfClass:NSNumber.class]) snapshot[@"fraction"] = state[@"fraction"];
    if ([state[@"error_code"] isKindOfClass:NSString.class] && [phase isEqual:@"failed"]) {
      snapshot[@"error_code"] = state[@"error_code"];
    }
    return snapshot;
  }
}

- (void)setInstallPhase:(NSString *)phase
               fraction:(NSNumber *)fraction
              errorCode:(NSString *)errorCode
             forHarness:(NSString *)harnessId {
  @synchronized (self) {
    NSMutableDictionary *state = self.installState[harnessId] ?: [NSMutableDictionary dictionary];
    state[@"phase"] = phase;
    if (fraction != nil) state[@"fraction"] = fraction; else [state removeObjectForKey:@"fraction"];
    if (errorCode != nil) state[@"error_code"] = errorCode; else [state removeObjectForKey:@"error_code"];
    self.installState[harnessId] = state;
  }
}

/// Begins a host-side download of the harness CLI. Idempotent: an install that
/// is already present or already running is left alone. Progress and the final
/// phase are read back through statusForHarnessId.
- (void)installCliForHarness:(NSString *)harnessId {
  NSDictionary *descriptor = [DSHHarnessAuthService cliDescriptorForHarness:harnessId];
  if (descriptor == nil) return;
  if ([DSHHarnessAuthService installedCliURLForHarness:harnessId] != nil) {
    [self setInstallPhase:@"ready" fraction:nil errorCode:nil forHarness:harnessId];
    return;
  }
  @synchronized (self) {
    if (self.installTasks[harnessId] != nil) return;
  }
  NSURL *directory = [DSHHarnessAuthService cliDirectory];
  if (directory == nil) {
    [self setInstallPhase:@"failed" fraction:nil errorCode:@"E_HARNESS_CLI_STORAGE_UNAVAILABLE"
               forHarness:harnessId];
    return;
  }
  [self setInstallPhase:@"downloading" fraction:@0 errorCode:nil forHarness:harnessId];
  NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
  configuration.timeoutIntervalForResource = 1800;
  NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration
                                                        delegate:self
                                                   delegateQueue:nil];
  __weak DSHHarnessAuthService *weakSelf = self;
  NSURL *target = [directory URLByAppendingPathComponent:descriptor[@"file"]];
  NSURLSessionDownloadTask *task = [session downloadTaskWithURL:[NSURL URLWithString:descriptor[@"url"]]
      completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
    DSHHarnessAuthService *strong = weakSelf;
    if (strong == nil) return;
    @synchronized (strong) { [strong.installTasks removeObjectForKey:harnessId]; }
    NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
    if (error != nil || http == nil || http.statusCode < 200 || http.statusCode >= 300 || location == nil) {
      [strong setInstallPhase:@"failed" fraction:nil errorCode:@"E_HARNESS_CLI_DOWNLOAD_FAILED"
                   forHarness:harnessId];
      return;
    }
    NSFileManager *files = NSFileManager.defaultManager;
    NSDictionary *attributes = [files attributesOfItemAtPath:location.path error:nil];
    if ([attributes[NSFileSize] unsignedLongLongValue] < DSHCliMinimumBytes) {
      [strong setInstallPhase:@"failed" fraction:nil errorCode:@"E_HARNESS_CLI_DOWNLOAD_TRUNCATED"
                   forHarness:harnessId];
      return;
    }
    // Replace atomically: a half-written target must never look installed.
    [files removeItemAtURL:target error:nil];
    NSError *moveError = nil;
    if (![files moveItemAtURL:location toURL:target error:&moveError]) {
      [strong setInstallPhase:@"failed" fraction:nil errorCode:@"E_HARNESS_CLI_STORE_FAILED"
                   forHarness:harnessId];
      return;
    }
    [files setAttributes:@{NSFileProtectionKey: NSFileProtectionComplete}
            ofItemAtPath:target.path error:nil];
    [strong setInstallPhase:@"ready" fraction:@1 errorCode:nil forHarness:harnessId];
  }];
  @synchronized (self) { self.installTasks[harnessId] = task; }
  [task resume];
}

- (void)URLSession:(NSURLSession *)session
              downloadTask:(NSURLSessionDownloadTask *)downloadTask
              didWriteData:(int64_t)bytesWritten
         totalBytesWritten:(int64_t)totalBytesWritten
 totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
  if (totalBytesExpectedToWrite <= 0) return;
  double fraction = (double)totalBytesWritten / (double)totalBytesExpectedToWrite;
  __block NSString *harness = nil;
  @synchronized (self) {
    for (NSString *key in self.installTasks) {
      if (self.installTasks[key] == downloadTask) { harness = key; break; }
    }
  }
  if (harness != nil) {
    [self setInstallPhase:@"downloading" fraction:@(MIN(1.0, MAX(0.0, fraction)))
                errorCode:nil forHarness:harness];
  }
}

- (NSDictionary *)statusForHarnessId:(NSString *)harnessId {
  if ([harnessId isEqual:@"claude-code"]) {
    DSHClaudeOfficialSession *runner = [self validatedClaudeSession];
    if (runner != nil) return runner.status;
    // No session yet means the CLI is not installed. Report unavailable with
    // the install snapshot so the card offers the download and shows progress.
    NSMutableDictionary *status = DSHAuthBaseStatus(harnessId,
        DSHAuthRuntime(NO, nil, @"cli-not-installed"));
    status[@"install"] = [self installSnapshotForHarness:harnessId];
    return status;
  }
  if (!DSHAuthSupportedHarness(harnessId)) return @{};
  // Codex signs in and chats host-side over HTTPS, so it needs no CLI and is
  // available at once. (Claude returned earlier through its own session, which
  // is gated on the CLI download.)
  BOOL available = [harnessId isEqualToString:DSHHarnessAuthHarnessCodex];
  NSString *reason = available ? nil : @"claude-original-auth-transport-unavailable";
  NSMutableDictionary *status = DSHAuthBaseStatus(
      harnessId,
      DSHAuthRuntime(available, nil, reason));
  if (available) {
    NSString *activeSession = nil;
    NSString *activeURL = nil;
    NSString *activeCode = nil;
    NSString *activePhase = nil;
    NSUInteger activeGeneration = 0;
    @synchronized (self) {
      activeSession = self.activeSessionId;
      activeURL = self.activeVerificationURL;
      activeCode = self.activeUserCode;
      activePhase = self.activePhase;
      activeGeneration = self.generation;
    }
    if (activeSession.length > 0 && activeGeneration > 0) {
      NSMutableDictionary *activeStatus = [DSHAuthStatusForActiveLogin(
          harnessId, activeSession, activeURL ?: @"https://auth.openai.com/codex/device",
          activeCode, [NSDate dateWithTimeIntervalSinceNow:600]) mutableCopy];
      if (self.activeErrorCode.length > 0) {
        activeStatus[@"status"] = @"error";
        activeStatus[@"error_code"] = self.activeErrorCode;
      }
      NSMutableDictionary *login = [activeStatus[@"login"] mutableCopy];
      login[@"phase"] = activePhase ?: (activeCode.length ? @"waiting_for_browser" : @"starting");
      activeStatus[@"login"] = login;
      return activeStatus;
    }
    if (self.lastErrorCode.length > 0) {
      status[@"status"] = @"error";
      status[@"error_code"] = self.lastErrorCode;
      return status;
    }
    OSStatus keychainStatus = errSecSuccess;
    NSData *credential = DSHAuthStoredCredential(harnessId, &keychainStatus);
    NSDictionary *json = credential == nil ? nil :
        [NSJSONSerialization JSONObjectWithData:credential options:0 error:nil];
    if (keychainStatus == errSecItemNotFound) {
      status[@"status"] = @"signed_out";
      status[@"auth_method"] = @"none";
    } else if (keychainStatus != errSecSuccess ||
               [DSHHarnessAuthService codexChatCredentialFromAuthJSON:json] == nil) {
      status[@"status"] = @"error";
      status[@"error_code"] = @"E_HARNESS_AUTH_CREDENTIAL_INVALID";
    } else {
      status[@"status"] = @"signed_in";
      status[@"auth_method"] = @"subscription";
      status[@"account"] = @{ @"label": @"subscription" };
    }
  }
  return status;
}

- (NSDictionary *)codexChatCredential {
  if (![[self codexChatSource] isEqualToString:DSHCodexChatSubscription]) return nil;
  OSStatus status = errSecSuccess;
  NSData *data = DSHAuthStoredCredential(DSHHarnessAuthHarnessCodex, &status);
  NSDictionary *json = data == nil ? nil : [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (!DSHCodexValidAuthJSON(json)) return nil;
  return [DSHHarnessAuthService codexChatCredentialFromAuthJSON:json];
}

- (void)ensureCodexChatCredential:(void (^)(NSDictionary *, NSString *))completion {
  if (!completion) return;
  dispatch_async(self.queue, ^{
    if (![[self codexChatSource] isEqualToString:DSHCodexChatSubscription]) {
      dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, nil); });
      return;
    }
    OSStatus status = errSecSuccess;
    NSData *data = DSHAuthStoredCredential(DSHHarnessAuthHarnessCodex, &status);
    id parsed = data == nil ? nil : [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSDictionary *json = [parsed isKindOfClass:NSDictionary.class] ? parsed : nil;
    NSDictionary *credential = [DSHHarnessAuthService codexChatCredentialFromAuthJSON:json];
    NSString *access = [json[@"tokens"][@"access_token"] isKindOfClass:NSString.class] ? json[@"tokens"][@"access_token"] : nil;
    if (credential != nil && access != nil && ![DSHHarnessAuthService codexAccessTokenNeedsRefresh:access now:[NSDate date]]) {
      dispatch_async(dispatch_get_main_queue(), ^{ completion(credential, nil); });
      return;
    }
    NSString *refresh = [json[@"tokens"][@"refresh_token"] isKindOfClass:NSString.class] ? json[@"tokens"][@"refresh_token"] : nil;
    if (refresh.length == 0) {
      dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, @"E_CODEX_AUTH_REQUIRED"); });
      return;
    }
    @synchronized (self) {
      [self.codexRefreshWaiters addObject:[completion copy]];
      if (self.codexRefreshInFlight) return;
      self.codexRefreshInFlight = YES;
    }
    NSUInteger generation;
    @synchronized (self) { generation = self.generation; }
    dispatch_async(self.workerQueue, ^{ [self performCodexRefreshWithGeneration:generation]; });
  });
}

- (void)performCodexRefreshWithGeneration:(NSUInteger)generation {
  OSStatus status = errSecSuccess;
  NSData *data = DSHAuthStoredCredential(DSHHarnessAuthHarnessCodex, &status);
  id parsed = data == nil ? nil : [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  NSDictionary *oldJSON = [parsed isKindOfClass:NSDictionary.class] ? parsed : nil;
  NSString *refresh = oldJSON[@"tokens"][@"refresh_token"];
  if (![refresh isKindOfClass:NSString.class] || refresh.length == 0) {
    [self completeCodexRefresh:nil errorCode:@"E_CODEX_AUTH_REQUIRED"];
    return;
  }
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:DSHCodexOAuthTokenURL]];
  request.HTTPMethod = @"POST";
  request.timeoutInterval = 20;
  [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
  NSMutableCharacterSet *formAllowed = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
  [formAllowed addCharactersInString:@"-._*"];
  NSString *encodedRefresh = [refresh stringByAddingPercentEncodingWithAllowedCharacters:formAllowed];
  NSString *body = [NSString stringWithFormat:@"client_id=%@&grant_type=refresh_token&refresh_token=%@", DSHCodexOAuthClientID, encodedRefresh ?: @""];
  request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
  NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
  configuration.timeoutIntervalForRequest = 20;
  configuration.timeoutIntervalForResource = 25;
  NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
  [[session dataTaskWithRequest:request completionHandler:^(NSData *responseData, NSURLResponse *response, NSError *error) {
    id responseObject = responseData.length <= 128 * 1024 ? (responseData == nil ? nil : [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil]) : nil;
    NSDictionary *responseJSON = [responseObject isKindOfClass:NSDictionary.class] ? responseObject : nil;
    NSDictionary *tokens = [responseJSON[@"tokens"] isKindOfClass:NSDictionary.class] ? responseJSON[@"tokens"] : responseJSON;
    NSString *access = [tokens[@"access_token"] isKindOfClass:NSString.class] ? tokens[@"access_token"] : nil;
    if (error || ![response isKindOfClass:NSHTTPURLResponse.class] || ((NSHTTPURLResponse *)response).statusCode < 200 || ((NSHTTPURLResponse *)response).statusCode >= 300 || access.length == 0) {
      [self completeCodexRefresh:nil errorCode:@"E_CODEX_AUTH_REFRESH_FAILED"]; return;
    }
    NSMutableDictionary *updated = [oldJSON mutableCopy];
    NSMutableDictionary *updatedTokens = [oldJSON[@"tokens"] mutableCopy] ?: [NSMutableDictionary dictionary];
    updatedTokens[@"access_token"] = access;
    if ([tokens[@"refresh_token"] isKindOfClass:NSString.class] && [tokens[@"refresh_token"] length]) updatedTokens[@"refresh_token"] = tokens[@"refresh_token"];
    if ([tokens[@"id_token"] isKindOfClass:NSString.class] && [tokens[@"id_token"] length]) updatedTokens[@"id_token"] = tokens[@"id_token"];
    updated[@"tokens"] = updatedTokens;
    updated[@"last_refresh"] = [[[NSISO8601DateFormatter alloc] init] stringFromDate:[NSDate date]];
    NSDictionary *credential = [DSHHarnessAuthService codexChatCredentialFromAuthJSON:updated];
    BOOL committed = NO;
    @synchronized (self) {
      if (self.generation == generation && [[self codexChatSource] isEqualToString:DSHCodexChatSubscription]) {
        OSStatus latestStatus = errSecSuccess;
        NSData *latestData = DSHAuthStoredCredential(DSHHarnessAuthHarnessCodex, &latestStatus);
        NSString *oldAccount = [credential[@"account_id"] isKindOfClass:NSString.class] ? credential[@"account_id"] : nil;
        NSDictionary *latestJSON = latestData.length ? [NSJSONSerialization JSONObjectWithData:latestData options:0 error:nil] : nil;
        NSDictionary *latestCredential = [DSHHarnessAuthService codexChatCredentialFromAuthJSON:latestJSON];
        NSString *latestAccount = [latestCredential[@"account_id"] isKindOfClass:NSString.class] ? latestCredential[@"account_id"] : nil;
        NSData *encoded = [NSJSONSerialization dataWithJSONObject:updated options:0 error:nil];
        committed = latestStatus == errSecSuccess && [latestData isEqualToData:data] && [oldAccount isEqualToString:latestAccount] && credential != nil && encoded.length > 0 && DSHAuthStoreCredential(DSHHarnessAuthHarnessCodex, encoded);
      }
    }
    [self completeCodexRefresh:committed ? credential : nil errorCode:committed ? nil : @"E_CODEX_AUTH_STALE"];
  } ] resume];
}

- (void)completeCodexRefresh:(NSDictionary *)credential errorCode:(NSString *)errorCode {
  NSArray *waiters;
  @synchronized (self) { waiters = [self.codexRefreshWaiters copy]; [self.codexRefreshWaiters removeAllObjects]; self.codexRefreshInFlight = NO; }
  for (void (^waiter)(NSDictionary *, NSString *) in waiters) dispatch_async(dispatch_get_main_queue(), ^{ waiter(credential, errorCode); });
}

static NSMutableDictionary *DSHAuthKeychainQuery(NSString *harnessId) {
  return [@{
    (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrService: DSHHarnessAuthKeychainService,
    (__bridge id)kSecAttrAccount: harnessId,
    (__bridge id)kSecAttrSynchronizable: @NO,
  } mutableCopy];
}

static NSData *DSHAuthStoredCredential(NSString *harnessId, OSStatus *statusOut) {
  NSMutableDictionary *query = DSHAuthKeychainQuery(harnessId);
  query[(__bridge id)kSecReturnData] = @YES;
  query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
  CFTypeRef result = nil;
  OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
  if (statusOut != NULL) *statusOut = status;
  return status == errSecSuccess && result != nil ? CFBridgingRelease(result) : nil;
}

static BOOL DSHAuthStoreCredential(NSString *harnessId, NSData *data) {
  NSMutableDictionary *query = DSHAuthKeychainQuery(harnessId);
  NSDictionary *attributes = @{
    (__bridge id)kSecValueData: data,
    (__bridge id)kSecAttrAccessible:
        (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
  };
  OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query,
                                  (__bridge CFDictionaryRef)attributes);
  if (status == errSecItemNotFound) {
    query[(__bridge id)kSecValueData] = data;
    query[(__bridge id)kSecAttrAccessible] =
        (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
    status = SecItemAdd((__bridge CFDictionaryRef)query, nil);
  }
  return status == errSecSuccess;
}

static NSDictionary *DSHAuthStatusForActiveLogin(NSString *harnessId,
                                                 NSString *sessionId,
                                                 NSString *url,
                                                 NSString *code,
                                                 NSDate *expiresAt) {
  NSMutableDictionary *status = [@{
    @"schema_version": @1, @"harness_id": harnessId,
    @"runtime": DSHAuthRuntime(YES, nil, nil),
    @"status": @"authorizing", @"auth_method": @"subscription",
    @"login": @{
      @"session_id": sessionId,
      @"verification_url": url,
      @"can_submit_code": @NO,
      @"expires_at": @((NSInteger)expiresAt.timeIntervalSince1970),
    },
  } mutableCopy];
  if (code.length > 0) status[@"login"] = @{
    @"session_id": sessionId, @"verification_url": url, @"user_code": code,
    @"can_submit_code": @NO,
    @"expires_at": @((NSInteger)expiresAt.timeIntervalSince1970),
  };
  return status;
}

- (void)finishAsync:(void (^)(NSDictionary *))completion
             status:(NSDictionary *)status {
  if (completion == nil) return;
  dispatch_async(dispatch_get_main_queue(), ^{ completion(status); });
}

- (void)startLoginForHarnessId:(NSString *)harnessId
                    completion:(void (^)(NSDictionary *))completion {
  if ([harnessId isEqual:@"claude-code"]) {
    DSHClaudeOfficialSession *runner = [self validatedClaudeSession];
    if (runner != nil) {
      [runner startLogin:^(NSDictionary *status) {
        if ([status[@"status"] isEqualToString:@"signed_in"]) {
          void (^changed)(void) = nil;
          @synchronized (self) { changed = [self.onClaudeChatCredentialChanged copy]; }
          if (changed) changed();
        }
        if (completion) completion(status);
      }];
    }
    else [self finishAsync:completion status:[self statusForHarnessId:harnessId]];
    return;
  }
  dispatch_async(self.queue, ^{
    NSMutableDictionary *status = [[self statusForHarnessId:harnessId] mutableCopy];
    if (status.count == 0) {
      [self finishAsync:completion status:@{ @"schema_version": @1,
        @"harness_id": harnessId ?: @"", @"status": @"error",
        @"auth_method": @"none", @"error_code": @"E_HARNESS_AUTH_INVALID_HARNESS" }];
      return;
    }
    if (![status[@"runtime"][ @"available"] boolValue]) {
      [self finishAsync:completion status:status];
      return;
    }
    NSString *sessionId = NSUUID.UUID.UUIDString.lowercaseString;
    NSUInteger generation = 0;
    @synchronized (self) {
      if (self.activeSessionId.length > 0) {
        status = [DSHAuthStatusForActiveLogin(
            harnessId, self.activeSessionId, self.activeVerificationURL,
            self.activeUserCode, [NSDate dateWithTimeIntervalSinceNow:600]) mutableCopy];
      } else {
        self.generation = self.generation == NSUIntegerMax ? 1 : self.generation + 1;
        generation = self.generation;
        self.activeSessionId = sessionId;
        self.activeVerificationURL = @"https://auth.openai.com/codex/device";
        self.activeUserCode = nil;
        self.activeErrorCode = nil;
        self.lastErrorCode = nil;
        self.loginOutput = [NSMutableData data];
        self.activePhase = @"starting";
        status = [DSHAuthStatusForActiveLogin(
            harnessId, sessionId, self.activeVerificationURL, nil,
            [NSDate dateWithTimeIntervalSinceNow:600]) mutableCopy];
      }
    }
    [self finishAsync:completion status:status];
    if (generation > 0) {
      dispatch_async(self.workerQueue, ^{
        [self runCodexLoginForSession:sessionId generation:generation];
      });
    }
  });
}

- (void)cancelLoginForHarnessId:(NSString *)harnessId
                      sessionId:(NSString *)sessionId
                     completion:(void (^)(NSDictionary *))completion {
  if ([harnessId isEqual:@"claude-code"]) {
    DSHClaudeOfficialSession *runner = [self validatedClaudeSession];
    if (runner != nil) [runner cancelSession:sessionId completion:completion];
    else [self finishAsync:completion status:[self statusForHarnessId:harnessId]];
    return;
  }
  dispatch_async(self.queue, ^{
    NSMutableDictionary *status = [[self statusForHarnessId:harnessId] mutableCopy];
    if (status.count == 0) {
      status = [@{ @"schema_version": @1, @"harness_id": harnessId ?: @"",
        @"status": @"error", @"auth_method": @"none",
        @"error_code": @"E_HARNESS_AUTH_INVALID_HARNESS" } mutableCopy];
    } else if (!DSHAuthValidSessionId(sessionId)) {
      status[@"status"] = @"error";
      status[@"error_code"] = @"E_HARNESS_AUTH_SESSION_INVALID";
    } else if ([status[@"status"] isEqualToString:@"authorizing"] &&
               [status[@"login"][ @"session_id"] isEqualToString:sessionId]) {
      @synchronized (self) {
        self.generation = self.generation == NSUIntegerMax ? 1 : self.generation + 1;
        self.activeSessionId = nil;
        self.activeVerificationURL = nil;
        self.activeUserCode = nil;
        self.activeErrorCode = nil;
        self.lastErrorCode = nil;
      }
      status[@"status"] = @"signed_out";
      status[@"auth_method"] = @"none";
      [status removeObjectForKey:@"login"];
    } else {
      status[@"status"] = @"error";
      status[@"error_code"] = @"E_HARNESS_AUTH_SESSION_NOT_FOUND";
    }
    [self finishAsync:completion status:status];
  });
}

- (void)logoutForHarnessId:(NSString *)harnessId
                completion:(void (^)(NSDictionary *))completion {
  if ([harnessId isEqual:@"claude-code"]) {
    DSHClaudeOfficialSession *runner = [self validatedClaudeSession];
    if (runner != nil) {
      [runner logout:^(NSDictionary *status) {
        void (^changed)(void) = nil;
        @synchronized (self) { changed = [self.onClaudeChatCredentialChanged copy]; }
        if (changed) changed();
        if (completion) completion(status);
      }];
    }
    else [self finishAsync:completion status:[self statusForHarnessId:harnessId]];
    return;
  }
  dispatch_async(self.queue, ^{
    if (!DSHAuthSupportedHarness(harnessId)) {
      [self finishAsync:completion status:@{ @"schema_version": @1,
        @"harness_id": harnessId ?: @"", @"status": @"error",
        @"auth_method": @"none", @"error_code": @"E_HARNESS_AUTH_INVALID_HARNESS" }];
      return;
    }
    if ([harnessId isEqualToString:DSHHarnessAuthHarnessCodex]) {
      @synchronized (self) {
        self.generation = self.generation == NSUIntegerMax ? 1 : self.generation + 1;
        self.activeSessionId = nil;
        self.activeVerificationURL = nil;
        self.activeUserCode = nil;
        self.activeErrorCode = nil;
      }
    }
    OSStatus keychainStatus = SecItemDelete(
        (__bridge CFDictionaryRef)DSHAuthKeychainQuery(harnessId));
    if ([harnessId isEqualToString:DSHHarnessAuthHarnessCodex]) {
      // Keep an explicit subscription choice across logout so a later login
      // cannot silently route through an API-key slot. API-key selection is
      // caller-owned and its marker is left untouched.
      NSString *selectedSource = [self codexChatSource];
      if (![selectedSource isEqualToString:DSHCodexChatSubscription] &&
          ![selectedSource isEqualToString:DSHCodexChatAPIKey] &&
          ![selectedSource isEqualToString:@"unavailable"]) {
        OSStatus sourceStatus = SecItemDelete((__bridge CFDictionaryRef)DSHCodexSourceQuery());
        if (sourceStatus != errSecSuccess && sourceStatus != errSecItemNotFound) keychainStatus = sourceStatus;
      }
    }
    if (keychainStatus != errSecSuccess && keychainStatus != errSecItemNotFound) {
      [self finishAsync:completion status:@{ @"schema_version": @1,
        @"harness_id": harnessId, @"status": @"error",
        @"auth_method": @"none", @"error_code": @"E_HARNESS_AUTH_KEYCHAIN" }];
      return;
    }
    void (^changed)(void);
    @synchronized (self) { changed = [self.onCodexChatCredentialChanged copy]; }
    if (changed) changed();
    [self finishAsync:completion status:[self statusForHarnessId:harnessId]];
  });
}

#pragma mark Guest CLI boot and install

/// The shared kernel and initramfs the app ships and pins -- the same guest
/// every runtime here boots. nil when the bundle is not the reviewed one.
static NSDictionary *DSHAuthSharedGuestAssets(NSBundle *bundle) {
  NSURL *kernel = [bundle URLForResource:DSHGuestKernelResourceName withExtension:nil];
  NSURL *initrd = [bundle URLForResource:DSHGuestInitramfsResourceName withExtension:nil];
  if (kernel == nil || initrd == nil) return nil;
  if (![DSHAuthSHA256File(kernel) isEqualToString:DSHGuestKernelSha256] ||
      ![DSHAuthSHA256File(initrd) isEqualToString:DSHGuestInitramfsSha256]) {
    return nil;
  }
  return @{ @"kernel_url": kernel, @"initrd_url": initrd };
}

/// The persistent guest HOME image for a harness, created sparse on first use.
/// Credentials the CLI writes and the installed CLI itself live here, so a
/// login survives to the next one. nil only when it cannot be created.
+ (NSURL *)homeDiskURLForHarness:(NSString *)harnessId {
  NSURL *directory = [self cliDirectory];
  if (directory == nil) return nil;
  NSString *name = [NSString stringWithFormat:@"%@-home.img",
      [harnessId isEqualToString:DSHHarnessAuthHarnessCodex] ? @"codex" : @"claude"];
  NSURL *disk = [directory URLByAppendingPathComponent:name];
  NSFileManager *files = NSFileManager.defaultManager;
  unsigned long long const bytes = 768ULL * 1024 * 1024;
  NSDictionary *attributes = [files attributesOfItemAtPath:disk.path error:nil];
  if ([attributes[NSFileType] isEqual:NSFileTypeRegular]) {
    if ([attributes[NSFileSize] unsignedLongLongValue] == bytes) return disk;
    [files removeItemAtURL:disk error:nil];
  }
  if (![files createFileAtPath:disk.path contents:nil
                    attributes:@{NSFileProtectionKey: NSFileProtectionComplete}]) {
    return nil;
  }
  NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:disk error:nil];
  if (handle == nil) return nil;
  BOOL sized = [handle truncateAtOffset:bytes error:nil] && [handle closeAndReturnError:nil];
  if (!sized) { [files removeItemAtURL:disk error:nil]; return nil; }
  [disk setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
  return disk;
}

/// One synchronous guest command; nil on any transport failure. Not for the
/// interactive login exec, which streams and takes stdin.
static NSDictionary *DSHAuthGuestExec(void *session, NSArray<NSString *> *command,
                                      NSUInteger timeoutMs) {
  NSData *encoded = [NSJSONSerialization dataWithJSONObject:@{
    @"protocol_version": @2, @"command": command,
    @"timeout_ms": @(timeoutMs), @"max_output_bytes": @(256 * 1024),
  } options:0 error:nil];
  if (encoded == nil) return nil;
  char *raw = rish_vm_session_exec_json(session, (const char *)encoded.bytes, encoded.length);
  if (raw == NULL) return nil;
  NSString *text = [NSString stringWithUTF8String:raw];
  rish_string_free(raw);
  if (text.length == 0 || text.length > 1024 * 1024) return nil;
  return [NSJSONSerialization JSONObjectWithData:
      [text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
}

/// Boots the guest with the persistent HOME disk and the downloaded CLI as a
/// data disk, mounts HOME exec, and installs the CLI into it on first use.
/// Returns a live session handle (fill *owner) or NULL with *errorCode set.
/// Codex ships a tar.gz; Claude a raw binary -- both land at /mnt/harness/cli.
- (void *)bootGuestForHarness:(NSString *)harnessId
                        owner:(DSHGuestVMOwner **)ownerOut
                    errorCode:(NSString **)errorCode {
  NSDictionary *assets = DSHAuthSharedGuestAssets(self.bundle);
  NSURL *cli = [DSHHarnessAuthService installedCliURLForHarness:harnessId];
  NSURL *home = [DSHHarnessAuthService homeDiskURLForHarness:harnessId];
  if (assets == nil) { if (errorCode) *errorCode = @"E_HARNESS_GUEST_ASSETS"; return NULL; }
  if (cli == nil) { if (errorCode) *errorCode = @"E_HARNESS_CLI_NOT_INSTALLED"; return NULL; }
  if (home == nil) { if (errorCode) *errorCode = @"E_HARNESS_CLI_STORAGE_UNAVAILABLE"; return NULL; }

  DSHGuestVMOwner *owner = [DSHGuestRuntimeState.sharedState acquireGuestOwner];
  if (owner == nil) { if (errorCode) *errorCode = @"E_GUEST_BUSY"; return NULL; }

  NSDictionary *request = @{
    @"kernel_path": [assets[@"kernel_url"] path],
    @"initrd_path": [assets[@"initrd_url"] path],
    @"root_disk_path": home.path,
    @"data_disk_path": cli.path,
    @"memory_mib": @1024,
    @"network": @"user-nat",
    @"command": @[],
    @"command_line": @"console=ttyS0,115200n8 rdinit=/init panic=-1 oops=panic nokaslr "
                     @"cgroup_no_v1=all 8250.nr_uarts=1",
    @"boot_budget_units": @60000000000ULL,
    @"handshake_budget_units": @40000000000ULL,
  };
  NSData *encoded = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
  void *session = encoded == nil ? NULL
      : rish_vm_boot_session((const char *)encoded.bytes, encoded.length);
  if (session == NULL) {
    [DSHGuestRuntimeState.sharedState releaseGuestOwner:owner];
    if (errorCode) *errorCode = @"E_GUEST_BOOT_FAILED";
    return NULL;
  }
  [DSHGuestRuntimeState.sharedState setGuestRuntimeMounted:YES owner:owner];

  // Format the HOME disk only when it was just created (a fresh sparse image
  // reads as zeros; a formatted one has a vfat signature). Mount it exec so the
  // installed CLI runs in place, then install from /dev/vdb if not already there.
  BOOL isCodex = [harnessId isEqualToString:DSHHarnessAuthHarnessCodex];
  NSString *setup = [NSString stringWithFormat:
      @"set -e; ip link set lo up;"
      @" if ! blkid /dev/vda >/dev/null 2>&1; then mkfs.vfat /dev/vda >/dev/null 2>&1; fi;"
      @" mkdir -p /mnt/harness;"
      @" mount -t vfat -o umask=0022 /dev/vda /mnt/harness;"
      @" mkdir -p /mnt/harness/home /mnt/harness/cli;"
      @" if [ ! -x /mnt/harness/cli/%@ ]; then%@ chmod 0755 /mnt/harness/cli/%@; fi;"
      @" test -x /mnt/harness/cli/%@",
      isCodex ? @"codex" : @"claude",
      isCodex ? @" tar -xzf /dev/vdb -C /mnt/harness/cli;"
                @" if [ ! -e /mnt/harness/cli/codex ]; then mv /mnt/harness/cli/codex-* /mnt/harness/cli/codex; fi;"
              : @" dd if=/dev/vdb of=/mnt/harness/cli/claude bs=1M 2>/dev/null;",
      isCodex ? @"codex" : @"claude",
      isCodex ? @"codex" : @"claude"];
  NSDictionary *reply = DSHAuthGuestExec(session, @[ @"sh", @"-lc", setup ], 600000);
  if (![reply[@"exit_code"] isEqual:@0]) {
    rish_vm_session_free(session);
    [DSHGuestRuntimeState.sharedState releaseGuestOwner:owner];
    if (errorCode) *errorCode = @"E_HARNESS_CLI_INSTALL_FAILED";
    return NULL;
  }
  if (ownerOut) *ownerOut = owner;
  return session;
}

- (void)runCodexLoginForSession:(NSString *)sessionId generation:(NSUInteger)generation {
  // The device-code exchange is plain HTTPS -- the same shape the token
  // refresh below already speaks -- so it runs on the host. It used to boot a
  // guest only to run the CLI's copy of this flow, which meant installing a
  // 98 MB binary on an emulated core before a single request could go out.
  // The endpoints are the CLI's own: auth.openai.com device authorization,
  // polling, and the OAuth token exchange with PKCE.
  // PKCE: a random verifier and its S256 challenge, as the CLI does.
  uint8_t verifierBytes[32];
  if (SecRandomCopyBytes(kSecRandomDefault, sizeof(verifierBytes), verifierBytes) != errSecSuccess) {
    [self finishCodexLoginWithGeneration:generation response:nil];
    return;
  }
  NSString *verifier = [[[NSData dataWithBytes:verifierBytes length:sizeof(verifierBytes)]
      base64EncodedStringWithOptions:0] stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
  verifier = [[verifier stringByReplacingOccurrencesOfString:@"/" withString:@"_"]
      stringByReplacingOccurrencesOfString:@"=" withString:@""];
  uint8_t digest[CC_SHA256_DIGEST_LENGTH];
  NSData *verifierData = [verifier dataUsingEncoding:NSUTF8StringEncoding];
  CC_SHA256(verifierData.bytes, (CC_LONG)verifierData.length, digest);
  NSString *challenge = [[[NSData dataWithBytes:digest length:sizeof(digest)]
      base64EncodedStringWithOptions:0] stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
  challenge = [[challenge stringByReplacingOccurrencesOfString:@"/" withString:@"_"]
      stringByReplacingOccurrencesOfString:@"=" withString:@""];

  // Step 1: ask for a device auth id and the user code.
  NSDictionary *usercode = [self codexAuthPOST:@"/api/accounts/deviceauth/usercode"
                                          json:@{ @"client_id": DSHCodexOAuthClientID }
                                     generation:generation session:sessionId];
  NSString *deviceAuthId = [usercode[@"device_auth_id"] isKindOfClass:NSString.class] ? usercode[@"device_auth_id"] : nil;
  NSString *userCode = [usercode[@"user_code"] isKindOfClass:NSString.class] ? usercode[@"user_code"] : nil;
  NSInteger interval = [usercode[@"interval"] isKindOfClass:NSNumber.class] ? MAX(1, [usercode[@"interval"] integerValue]) : 5;
  if (deviceAuthId.length == 0 || userCode.length == 0) {
    [self finishCodexLoginWithGeneration:generation response:nil];
    return;
  }
  @synchronized (self) {
    if (self.generation != generation || ![self.activeSessionId isEqualToString:sessionId]) return;
    self.activeUserCode = userCode;
    self.activePhase = @"waiting_for_browser";
  }

  // Step 2: poll until the person approves, up to fifteen minutes.
  NSString *authorizationCode = nil;
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:900];
  while ([deadline timeIntervalSinceNow] > 0) {
    @synchronized (self) {
      if (self.generation != generation || ![self.activeSessionId isEqualToString:sessionId]) return;
    }
    [NSThread sleepForTimeInterval:interval];
    NSDictionary *poll = [self codexAuthPOST:@"/api/accounts/deviceauth/token"
                                        json:@{ @"device_auth_id": deviceAuthId, @"user_code": userCode }
                                   generation:generation session:sessionId];
    id code = poll[@"authorization_code"];
    if ([code isKindOfClass:NSString.class] && [code length] > 0) { authorizationCode = code; break; }
  }
  if (authorizationCode.length == 0) {
    @synchronized (self) {
      if (self.generation == generation && [self.activeSessionId isEqualToString:sessionId]) {
        self.activeErrorCode = @"E_HARNESS_AUTH_TIMED_OUT";
        self.lastErrorCode = self.activeErrorCode;
      }
    }
    [self finishCodexLoginWithGeneration:generation response:nil];
    return;
  }
  @synchronized (self) { if (self.generation == generation) self.activePhase = @"verifying"; }

  // Step 3: exchange the authorization code for tokens with the PKCE verifier.
  NSMutableCharacterSet *formAllowed = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
  [formAllowed addCharactersInString:@"-._*"];
  NSString *(^enc)(NSString *) = ^(NSString *value) {
    return [value stringByAddingPercentEncodingWithAllowedCharacters:formAllowed] ?: @"";
  };
  NSString *redirect = @"https://auth.openai.com/deviceauth/callback";
  NSString *body = [NSString stringWithFormat:
      @"grant_type=authorization_code&client_id=%@&code=%@&redirect_uri=%@&code_verifier=%@",
      DSHCodexOAuthClientID, enc(authorizationCode), enc(redirect), enc(verifier)];
  NSDictionary *tokens = [self codexTokenExchange:body generation:generation session:sessionId];
  NSString *access = [tokens[@"access_token"] isKindOfClass:NSString.class] ? tokens[@"access_token"] : nil;
  if (access.length == 0) {
    [self finishCodexLoginWithGeneration:generation response:nil];
    return;
  }

  // Persist in the auth.json shape the rest of this file already reads.
  NSMutableDictionary *tokenBlock = [@{ @"access_token": access } mutableCopy];
  if ([tokens[@"refresh_token"] isKindOfClass:NSString.class]) tokenBlock[@"refresh_token"] = tokens[@"refresh_token"];
  if ([tokens[@"id_token"] isKindOfClass:NSString.class]) tokenBlock[@"id_token"] = tokens[@"id_token"];
  NSDictionary *authJSON = @{ @"OPENAI_API_KEY": [NSNull null], @"tokens": tokenBlock,
      @"last_refresh": [[[NSISO8601DateFormatter alloc] init] stringFromDate:[NSDate date]] };
  if ([DSHHarnessAuthService codexChatCredentialFromAuthJSON:authJSON] == nil) {
    [self finishCodexLoginWithGeneration:generation response:nil];
    return;
  }
  NSData *encoded = [NSJSONSerialization dataWithJSONObject:authJSON options:0 error:nil];
  BOOL committed = NO;
  @synchronized (self) {
    if (encoded.length > 0 && self.generation == generation &&
        [self.activeSessionId isEqualToString:sessionId]) {
      committed = DSHAuthStoreCredential(DSHHarnessAuthHarnessCodex, encoded);
    }
  }
  [self finishCodexLoginWithGeneration:generation response:committed ? @{} : nil];
}

/// One synchronous JSON POST to the OpenAI auth API, returning the parsed
/// object or nil. Bounded response, host-checked, TLS validated by the system.
- (NSDictionary *)codexAuthPOST:(NSString *)path
                           json:(NSDictionary *)payload
                     generation:(NSUInteger)generation
                        session:(NSString *)sessionId {
  NSURL *url = [NSURL URLWithString:[@"https://auth.openai.com" stringByAppendingString:path]];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = @"POST";
  request.timeoutInterval = 20;
  [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  request.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
  if (request.HTTPBody == nil) return nil;
  return [self codexSynchronousJSON:request generation:generation session:sessionId];
}

/// The form-encoded token exchange, kept separate because its content type and
/// body differ from the JSON device-code calls.
- (NSDictionary *)codexTokenExchange:(NSString *)body
                          generation:(NSUInteger)generation
                             session:(NSString *)sessionId {
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:DSHCodexOAuthTokenURL]];
  request.HTTPMethod = @"POST";
  request.timeoutInterval = 20;
  [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
  request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *response = [self codexSynchronousJSON:request generation:generation session:sessionId];
  return [response[@"tokens"] isKindOfClass:NSDictionary.class] ? response[@"tokens"] : response;
}

- (NSDictionary *)codexSynchronousJSON:(NSURLRequest *)request
                            generation:(NSUInteger)generation
                               session:(NSString *)sessionId {
  NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
  configuration.timeoutIntervalForRequest = 20;
  configuration.timeoutIntervalForResource = 25;
  NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  __block NSDictionary *result = nil;
  [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
    if (error == nil && http != nil && http.statusCode >= 200 && http.statusCode < 300 &&
        data.length > 0 && data.length <= 128 * 1024) {
      id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
      if ([object isKindOfClass:NSDictionary.class]) result = object;
    }
    dispatch_semaphore_signal(done);
  }] resume];
  dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)));
  [session finishTasksAndInvalidate];
  return result;
}

- (void)finishCodexLoginWithGeneration:(NSUInteger)generation
                              response:(NSDictionary *)response {
  void (^changed)(void) = nil;
  @synchronized (self) {
    if (self.generation != generation) return;
    self.loginOutput = nil;
    if (response != nil) {
      NSData *sourceData = [DSHCodexChatSubscription dataUsingEncoding:NSUTF8StringEncoding];
      NSMutableDictionary *sourceQuery = DSHCodexSourceQuery();
      NSDictionary *sourceAttrs = @{(__bridge id)kSecValueData:sourceData, (__bridge id)kSecAttrAccessible:(__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly};
      OSStatus sourceStatus = SecItemUpdate((__bridge CFDictionaryRef)sourceQuery, (__bridge CFDictionaryRef)sourceAttrs);
      if (sourceStatus == errSecItemNotFound) { sourceQuery[(__bridge id)kSecValueData] = sourceData; sourceQuery[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly; SecItemAdd((__bridge CFDictionaryRef)sourceQuery, nil); }
      changed = [self.onCodexChatCredentialChanged copy];
      self.activeSessionId = nil;
      self.activeVerificationURL = nil;
      self.activeUserCode = nil;
      self.activeErrorCode = nil;
    } else {
      self.activeErrorCode = @"E_HARNESS_AUTH_FAILED";
      self.lastErrorCode = self.activeErrorCode;
      self.activeSessionId = nil;
    }
  }
  if (changed) changed();
}

- (void)receiveStreamEvent:(const char *)event length:(size_t)length {
  NSData *data = [NSData dataWithBytes:event length:length];
  NSDictionary *envelope = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![envelope isKindOfClass:NSDictionary.class] ||
      ![envelope[@"protocol_version"] isEqual:@1] ||
      ![envelope[@"event"] isEqual:@"output"] ||
      ![envelope[@"data_base64"] isKindOfClass:NSString.class]) return;
  NSData *bytes = [[NSData alloc] initWithBase64EncodedString:envelope[@"data_base64"] options:0];
  if (bytes.length == 0 || bytes.length > DSHHarnessAuthMaxOutputBytes) return;
  @synchronized (self) {
    if (!self.activeSessionId || self.streamGeneration != self.generation ||
        self.activeUserCode.length > 0) return;
    if (!self.loginOutput) self.loginOutput = [NSMutableData data];
    NSUInteger remaining = DSHHarnessAuthMaxOutputBytes - self.loginOutput.length;
    [self.loginOutput appendData:[bytes subdataWithRange:NSMakeRange(0, MIN(remaining, bytes.length))]];
    NSString *text = [[NSString alloc] initWithData:self.loginOutput encoding:NSUTF8StringEncoding];
    if (text.length == 0) return;
    NSDictionary *fields = [DSHHarnessAuthService safeLoginFieldsFromOfficialOutput:text harnessId:DSHHarnessAuthHarnessCodex];
    if (fields[@"verification_url"] != nil) self.activeVerificationURL = fields[@"verification_url"];
    if (fields[@"user_code"] != nil) self.activeUserCode = fields[@"user_code"];
    if (fields[@"user_code"] != nil && [self.activePhase isEqual:@"starting"]) self.activePhase = @"waiting_for_browser";
  }
}

- (void)presentLoginCodeForHarnessId:(NSString *)harnessId
                           sessionId:(NSString *)sessionId
                              locale:(NSString *)locale
                          completion:(void (^)(NSDictionary *))completion {
  (void)locale;
  dispatch_async(self.queue, ^{
    NSMutableDictionary *status = [[self statusForHarnessId:harnessId] mutableCopy];
    if (status.count == 0) {
      status = [@{ @"schema_version": @1, @"harness_id": harnessId ?: @"",
        @"status": @"error", @"auth_method": @"none",
        @"error_code": @"E_HARNESS_AUTH_INVALID_HARNESS" } mutableCopy];
    } else if (!DSHAuthValidSessionId(sessionId)) {
      status[@"status"] = @"error";
      status[@"error_code"] = @"E_HARNESS_AUTH_SESSION_INVALID";
    } else if ([status[@"status"] isEqualToString:@"authorizing"] &&
               [status[@"login"][ @"session_id"] isEqualToString:sessionId]) {
      // The caller presents the fixed, validated URL in its browser. No host
      // or query is taken from untrusted process output here.
    } else {
      status[@"status"] = @"error";
      status[@"error_code"] = @"E_HARNESS_AUTH_SESSION_NOT_FOUND";
    }
    [self finishAsync:completion status:status];
  });
}

- (void)authorizationBrowserDidCloseForSession:(NSString *)session {
  @synchronized (self) {
    if ([self.activeSessionId isEqual:session]) self.activePhase = @"verifying";
  }
}

+ (NSString *)pasteableDeviceCode:(NSString *)code {
  if (![code isKindOfClass:NSString.class] || code.length > 64) return nil;
  NSMutableString *result = [NSMutableString string];
  NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@"-‐‑‒–—− \t\r\n"];
  for (NSUInteger i = 0; i < code.length; i++) {
    unichar c = [code characterAtIndex:i];
    if ([separators characterIsMember:c]) continue;
    if (c >= 'a' && c <= 'z') c -= 'a' - 'A';
    if (!((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))) return nil;
    [result appendFormat:@"%C", c];
  }
  return result.length == 9 ? result : nil;
}

+ (NSDictionary *)safeLoginFieldsFromOfficialOutput:(NSString *)output
                                            harnessId:(NSString *)harnessId {
  if (![output isKindOfClass:NSString.class] || output.length == 0 ||
      !DSHAuthSupportedHarness(harnessId)) return @{};
  NSData *data = [output dataUsingEncoding:NSUTF8StringEncoding];
  if (data.length > DSHHarnessAuthMaxOutputBytes) {
    data = [data subdataWithRange:NSMakeRange(0, DSHHarnessAuthMaxOutputBytes)];
    output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  }
  NSMutableDictionary *result = [NSMutableDictionary dictionary];
  if (output.length == 0) return result;
  NSRegularExpression *ansi = [NSRegularExpression regularExpressionWithPattern:@"\\x1b\\[[0-?]*[ -/]*[@-~]" options:0 error:nil];
  output = [ansi stringByReplacingMatchesInString:output options:0 range:NSMakeRange(0, output.length) withTemplate:@""];
  NSMutableArray<NSString *> *plainLines = [NSMutableArray array];
  // Codex's official app-server device-code response is JSON-RPC. Accept only
  // the two public display fields and discard loginId, tokens, and all other
  // properties before anything reaches the bridge.
  for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
    NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
    id parsed = lineData == nil
        ? nil
        : [NSJSONSerialization JSONObjectWithData:lineData options:NSJSONReadingFragmentsAllowed error:nil];
    if (parsed == nil) {
      NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
      if (![trimmed hasPrefix:@"{"] && ![trimmed hasPrefix:@"["]) [plainLines addObject:line];
      continue;
    }
    if (![parsed isKindOfClass:NSDictionary.class]) continue;
    NSDictionary *message = parsed;
    NSDictionary *payload = [message[@"result"] isKindOfClass:NSDictionary.class]
        ? message[@"result"] : message;
    if (![payload isKindOfClass:NSDictionary.class]) continue;
    NSArray *urlKeys = @[ @"verificationUrl", @"verification_url" ];
    for (NSString *key in urlKeys) {
      NSString *safeURL = DSHAuthSafeVerificationURL(payload[key], harnessId);
      if (safeURL != nil) {
        result[@"verification_url"] = safeURL;
        break;
      }
    }
    NSArray *codeKeys = @[ @"userCode", @"user_code" ];
    for (NSString *key in codeKeys) {
      NSString *safeCode = DSHAuthSafeUserCode(payload[key]);
      if (safeCode != nil) {
        result[@"user_code"] = safeCode;
        break;
      }
    }
  }
  // Structured output is validated above. Never reinterpret rejected JSON
  // fields (for example userCode:false) as terminal display text.
  output = [plainLines componentsJoinedByString:@"\n"];
  NSRegularExpression *urlExpression = [NSRegularExpression
      regularExpressionWithPattern:@"https://[^\\s<>\\\"']+"
                             options:0 error:nil];
  for (NSTextCheckingResult *match in [urlExpression
           matchesInString:output options:0 range:NSMakeRange(0, output.length)]) {
    NSString *candidate = [output substringWithRange:match.range];
    NSString *safeURL = DSHAuthSafeVerificationURL(candidate, harnessId);
    if (safeURL != nil) {
      result[@"verification_url"] = safeURL;
      break;
    }
  }
  NSRegularExpression *codeExpression = [NSRegularExpression
      regularExpressionWithPattern:@"(?i)(?:user|device)[ -]?code\\s*[:=]\\s*([A-Z0-9]{4,12}(?:-[A-Z0-9]{4,12})?)(?![A-Z0-9-])"
                             options:0 error:nil];
  NSTextCheckingResult *codeMatch = [codeExpression firstMatchInString:output
                                                                 options:0
                                                                   range:NSMakeRange(0, output.length)];
  if (codeMatch.numberOfRanges > 1 && result[@"user_code"] == nil) {
    NSString *safeCode = DSHAuthSafeUserCode(
        [output substringWithRange:[codeMatch rangeAtIndex:1]]);
    if (safeCode != nil) result[@"user_code"] = safeCode;
  }
  if (result[@"user_code"] == nil) {
    NSRegularExpression *oneTime = [NSRegularExpression regularExpressionWithPattern:
      @"(?im)one-time code[^\\r\\n]*\\r?\\n[ \\t\\r\\n]*(?:\\(expires[^\\r\\n]*\\)[ \\t\\r\\n]*)?([A-Z0-9]{4,12}(?:-[A-Z0-9]{4,12})?)[ \\t]*(?:\\r?\\n|$)"
      options:0 error:nil];
    NSTextCheckingResult *match = [oneTime firstMatchInString:output options:0 range:NSMakeRange(0, output.length)];
    if (match.numberOfRanges > 1) {
      NSString *code = DSHAuthSafeUserCode([output substringWithRange:[match rangeAtIndex:1]]);
      if (code) result[@"user_code"] = code;
    }
  }
  return result;
}

@end
