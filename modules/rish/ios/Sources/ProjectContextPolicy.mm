#import "ProjectContextPolicy.h"

#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonHMAC.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Security/Security.h>

#include "rish_agent_core.h"

#include <ctype.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <atomic>

NSString *const DSHProjectContextPolicyVersion = @"chat-read-v1.0.0";

const NSUInteger DSHProjectContextMaxEntries = 5000;
const NSUInteger DSHProjectContextMaxDepth = 24;
const NSUInteger DSHProjectContextMaxFiles = 32;
const NSUInteger DSHProjectContextMaxFileBytes = 64 * 1024;
const NSUInteger DSHProjectContextMaxChangedPaths = 100;
const NSUInteger DSHProjectContextMaxDiffBytes = 128 * 1024;
const NSUInteger DSHProjectContextMaxContextBytes = 256 * 1024;
const NSTimeInterval DSHProjectContextDeadlineSeconds = 2.0;
const NSUInteger DSHProjectContextMaxCandidatePageSize = 100;
const NSUInteger DSHProjectContextMaxRelativePathCharacters = 4096;
const NSUInteger DSHProjectContextMaxQueryCharacters = 256;
const NSUInteger DSHProjectContextMaxSourceFingerprintCharacters = 256;

NSString *const DSHProjectContextOmissionReasonSecretPath = @"secret_path";
NSString *const DSHProjectContextOmissionReasonGenerated = @"generated";
NSString *const DSHProjectContextOmissionReasonLockfile = @"lockfile";
NSString *const DSHProjectContextOmissionReasonSuspectedSecret = @"suspected_secret";
NSString *const DSHProjectContextOmissionReasonBinary = @"binary";
NSString *const DSHProjectContextOmissionReasonInvalidEncoding = @"invalid_encoding";
NSString *const DSHProjectContextOmissionReasonNotTracked = @"not_tracked";
NSString *const DSHProjectContextOmissionReasonBudgetExceeded = @"budget_exceeded";
NSString *const DSHProjectContextOmissionReasonPolicy = @"policy";

NSErrorDomain const DSHProjectContextPolicyErrorDomain =
    @"dev.zseven.dsh.project-context-policy";

static const uint8_t DSHCursorVersion = 1;
static const NSUInteger DSHCursorPayloadBytes = 1 + sizeof(uint64_t) + CC_SHA256_DIGEST_LENGTH;
static const NSUInteger DSHCursorBytes = DSHCursorPayloadBytes + CC_SHA256_DIGEST_LENGTH;
static const NSUInteger DSHCursorEncodedCharacters = 98;
static const NSUInteger DSHCandidatePathMaxBytes = 4096;
static const NSUInteger DSHCandidateRevisionMaxBytes = 512;
static const NSUInteger DSHCandidateKeyMaxCharacters = 15;
static const NSUInteger DSHCandidateGitStateMaxCharacters = 10;
static const NSUInteger DSHCandidateOmissionReasonMaxCharacters = 16;

#if DEBUG
static std::atomic<NSUInteger> DSHCredentialScanWorkForTesting{0};
void DSHProjectContextPolicyResetCredentialScanWorkForTesting(void) {
  DSHCredentialScanWorkForTesting.store(0, std::memory_order_relaxed);
}

NSUInteger DSHProjectContextPolicyCredentialScanWorkForTesting(void) {
  return DSHCredentialScanWorkForTesting.load(std::memory_order_relaxed);
}

static void DSHRecordCredentialScanWork(NSUInteger units) {
  DSHCredentialScanWorkForTesting.fetch_add(units, std::memory_order_relaxed);
}
#else
static void DSHRecordCredentialScanWork(NSUInteger units) {
}
#endif

@interface DSHProjectContextPathDecision ()
@property(nonatomic, copy, readwrite) NSString *normalizedPath;
@property(nonatomic, readwrite, getter=isEligible) BOOL eligible;
@property(nonatomic, copy, readwrite, nullable) NSString *omissionReason;
- (instancetype)initWithNormalizedPath:(NSString *)normalizedPath
                              eligible:(BOOL)eligible
                         omissionReason:(nullable NSString *)omissionReason;
@end

@implementation DSHProjectContextPathDecision
- (instancetype)initWithNormalizedPath:(NSString *)normalizedPath
                              eligible:(BOOL)eligible
                         omissionReason:(nullable NSString *)omissionReason {
  self = [super init];
  if (self) {
    _normalizedPath = [normalizedPath copy];
    _eligible = eligible;
    _omissionReason = [omissionReason copy];
  }
  return self;
}
@end

@interface DSHProjectContextContentDecision ()
@property(nonatomic, readwrite, getter=isEligible) BOOL eligible;
@property(nonatomic, copy, readwrite, nullable) NSString *omissionReason;
- (instancetype)initWithEligible:(BOOL)eligible
                   omissionReason:(nullable NSString *)omissionReason;
@end

@implementation DSHProjectContextContentDecision
- (instancetype)initWithEligible:(BOOL)eligible
                   omissionReason:(nullable NSString *)omissionReason {
  self = [super init];
  if (self) {
    _eligible = eligible;
    _omissionReason = [omissionReason copy];
  }
  return self;
}
@end

@interface DSHProjectContextSecretDecision ()
@property(nonatomic, readwrite) BOOL suspectedSecret;
@property(nonatomic, copy, readwrite, nullable) NSString *omissionReason;
- (instancetype)initWithSuspectedSecret:(BOOL)suspectedSecret
                          omissionReason:(nullable NSString *)omissionReason;
@end

@implementation DSHProjectContextSecretDecision
- (instancetype)initWithSuspectedSecret:(BOOL)suspectedSecret
                          omissionReason:(nullable NSString *)omissionReason {
  self = [super init];
  if (self) {
    _suspectedSecret = suspectedSecret;
    _omissionReason = [omissionReason copy];
  }
  return self;
}
@end

@interface DSHProjectContextPolicy ()
@property(nonatomic, copy) NSData *cursorKey;
- (nullable NSString *)encodeCursorForSourceFingerprint:(NSString *)sourceFingerprint
                                                  offset:(NSUInteger)offset
                                     authenticationScope:(NSData *)authenticationScope
                                                   error:(NSError *_Nullable *_Nullable)error;
- (BOOL)decodeCursor:(NSString *)cursor
    sourceFingerprint:(NSString *)sourceFingerprint
  authenticationScope:(NSData *)authenticationScope
               offset:(NSUInteger *_Nullable)offset
                error:(NSError *_Nullable *_Nullable)error;
@end

static NSString *DSHNFCString(NSString *value) {
  return [value precomposedStringWithCanonicalMapping];
}

static NSString *DSHFoldedString(NSString *value) {
  NSMutableString *folded = [DSHNFCString(value) mutableCopy];
  CFStringFold((__bridge CFMutableStringRef)folded,
               kCFCompareCaseInsensitive,
               NULL);
  return DSHNFCString(folded);
}

// chat-read-v1's path tables live in the shared core (modules/rish/core,
// `rish_agent_project_context_reduce`): which directory, name or extension is
// a secret, generated output, a lockfile or a binary, and the order those are
// consulted in. A path that stops being recognised as sensitive is a secret
// sent to a provider, so there is one copy of that table.
//
// Case folding stays here. Foundation folds with CFStringFold, which is
// Unicode case *folding* — not lowercasing — and the core carries no folding
// table; the same shape as the foundation-json-v1 projection. So this side
// folds, exactly as it always did, and passes the folded spellings across.
static NSDictionary *DSHPolicyReduce(NSString *op, NSDictionary *fields) {
  NSMutableDictionary *envelope = [fields mutableCopy];
  envelope[@"op"] = op;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:envelope options:0
                                                    error:nil];
  char *raw = bytes == nil ? NULL : rish_agent_project_context_reduce(
      (const char *)bytes.bytes, bytes.length);
  if (raw == NULL) return nil;
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0
                                                error:nil];
  return [reply isKindOfClass:NSDictionary.class] &&
      [reply[@"ok"] isEqual:@YES] ? reply : nil;
}

/// One component as the core needs to see it: folded, plus the two Foundation
/// path operations applied to the folded spelling.
static NSDictionary *DSHFoldedComponent(NSString *component) {
  NSString *folded = DSHFoldedString(component);
  return @{
    @"folded" : folded,
    @"extension" : folded.pathExtension ?: @"",
    @"stem" : folded.stringByDeletingPathExtension ?: @"",
  };
}

static BOOL DSHRelativePathHasSafeStructure(NSString *normalizedPath) {
  unichar firstCharacter =
      normalizedPath.length > 0 ? [normalizedPath characterAtIndex:0] : 0;
  BOOL firstCharacterIsASCIILetter =
      (firstCharacter >= 'A' && firstCharacter <= 'Z') ||
      (firstCharacter >= 'a' && firstCharacter <= 'z');
  BOOL absoluteWindowsPath =
      normalizedPath.length >= 3 && firstCharacterIsASCIILetter &&
      [normalizedPath characterAtIndex:1] == ':' &&
      ([normalizedPath characterAtIndex:2] == '/' ||
       [normalizedPath characterAtIndex:2] == '\\');
  if (normalizedPath.length == 0 || [normalizedPath hasPrefix:@"/"] ||
      [normalizedPath hasPrefix:@"~/"] || absoluteWindowsPath ||
      [normalizedPath containsString:@"\\"] ||
      [normalizedPath rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet]
              .location != NSNotFound) {
    return NO;
  }

  NSArray<NSString *> *components =
      [normalizedPath componentsSeparatedByString:@"/"];
  if (components.count > DSHProjectContextMaxDepth) {
    return NO;
  }
  for (NSString *component in components) {
    if (component.length == 0 || [component isEqualToString:@"."] ||
        [component isEqualToString:@".."]) {
      return NO;
    }
  }
  return YES;
}

static NSError *DSHPolicyError(DSHProjectContextPolicyErrorCode code) {
  NSString *message = @"Project context policy input is invalid.";
  if (code == DSHProjectContextPolicyErrorInvalidCursor) {
    message = @"Project context cursor is invalid.";
  } else if (code == DSHProjectContextPolicyErrorStaleCursor) {
    message = @"Project context cursor is stale.";
  } else if (code == DSHProjectContextPolicyErrorBudgetExceeded) {
    message = @"Project context policy budget exceeded.";
  }
  return [NSError errorWithDomain:DSHProjectContextPolicyErrorDomain
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey : message}];
}

static void DSHSetPolicyError(NSError **error,
                              DSHProjectContextPolicyErrorCode code) {
  if (error != nil) {
    *error = DSHPolicyError(code);
  }
}

static NSSet<NSString *> *DSHSensitiveDirectories(void) {
  static NSSet<NSString *> *values;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    values = [NSSet setWithArray:@[
      @".git", @".hg", @".svn", @".ssh", @".aws", @".gnupg", @".kube",
      @".docker", @".env", @".m2", @"secret", @"secrets"
    ]];
  });
  return values;
}

static NSSet<NSString *> *DSHGeneratedDirectories(void) {
  static NSSet<NSString *> *values;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    values = [NSSet setWithArray:@[
      @"node_modules", @"vendor", @"pods", @".build", @"build", @"dist",
      @"generated", @"out", @"target", @"deriveddata", @".gradle", @".next",
      @"coverage", @"cache", @"tmp"
    ]];
  });
  return values;
}

static NSSet<NSString *> *DSHSensitiveExtensions(void) {
  static NSSet<NSString *> *values;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    values = [NSSet setWithArray:@[
      @"pem", @"key", @"p12", @"pfx", @"jks", @"keystore", @"mobileprovision"
    ]];
  });
  return values;
}

static NSSet<NSString *> *DSHBinaryExtensions(void) {
  static NSSet<NSString *> *values;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    values = [NSSet setWithArray:@[
      @"7z", @"a", @"apk", @"app", @"avi", @"bin", @"bmp", @"class", @"db",
      @"dmg", @"doc", @"docx", @"dylib", @"eot", @"exe", @"gif", @"gz",
      @"heic", @"ico", @"jar", @"jpeg", @"jpg", @"mov", @"mp3", @"mp4",
      @"o", @"otf", @"pdf", @"png", @"ppt", @"pptx", @"rar", @"sqlite",
      @"tar", @"tgz", @"ttf", @"wav", @"webm", @"webp", @"woff", @"woff2",
      @"pyc", @"pyo", @"wasm", @"xls", @"xlsx", @"xz", @"zip"
    ]];
  });
  return values;
}

static NSSet<NSString *> *DSHAllowedTextExtensions(void) {
  static NSSet<NSString *> *values;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    values = [NSSet setWithArray:@[
      @"adoc", @"bash", @"c", @"cc", @"cfg", @"conf", @"cpp", @"cs", @"css",
      @"csv", @"cxx", @"dart", @"entitlements", @"fish", @"gql", @"go",
      @"gradle", @"graphql",
      @"h", @"hh", @"hpp", @"htm", @"html", @"hxx", @"ini", @"java", @"js",
      @"json", @"jsonc", @"jsx", @"kt", @"kts", @"less", @"lua", @"m",
      @"markdown", @"md", @"mm", @"pbxproj", @"php", @"plist", @"properties",
      @"proto", @"ps1", @"py", @"r", @"rb", @"rs", @"rst", @"sass", @"scala",
      @"scss", @"sh", @"sql", @"storyboard", @"strings", @"swift", @"tex",
      @"toml", @"ts", @"tsv", @"tsx", @"txt", @"xib", @"xcconfig", @"xml",
      @"vue", @"xsd", @"yaml", @"yml", @"zsh"
    ]];
  });
  return values;
}

static BOOL DSHIsSafeBasename(NSString *foldedFilename) {
  return [foldedFilename hasPrefix:@"readme"] ||
         [foldedFilename hasPrefix:@"license"] ||
         [foldedFilename isEqualToString:@"dockerfile"] ||
         [foldedFilename isEqualToString:@"makefile"] ||
         [foldedFilename isEqualToString:@"cargo.toml"] ||
         [foldedFilename isEqualToString:@"package.json"] ||
         [foldedFilename isEqualToString:@".gitignore"];
}

static BOOL DSHIsLockfile(NSString *foldedFilename) {
  if ([foldedFilename hasSuffix:@".lock"]) {
    return YES;
  }
  static NSSet<NSString *> *values;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    values = [NSSet setWithArray:@[
      @"bun.lockb", @"composer.lock", @"package-lock.json", @"packages.lock.json",
      @"npm-shrinkwrap.json", @"pnpm-lock.yaml", @"shrinkwrap.yaml", @"uv.lock",
      @"yarn.lock"
    ]];
  });
  return [values containsObject:foldedFilename];
}

static BOOL DSHHasSensitiveDottedPrefix(NSString *foldedComponent) {
  for (NSString *prefix in @[ @"credential", @"credentials", @"secret", @"secrets" ]) {
    if ([foldedComponent hasPrefix:[prefix stringByAppendingString:@"."]]) {
      return YES;
    }
  }
  return NO;
}

static BOOL DSHIsSensitiveFilename(NSString *foldedFilename) {
  if ([foldedFilename hasPrefix:@".env"]) {
    return YES;
  }
  NSString *stem = [foldedFilename stringByDeletingPathExtension];
  static NSSet<NSString *> *values;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    values = [NSSet setWithArray:@[
      @"credential", @"credentials", @"id_ed25519", @"id_rsa", @"secret", @"secrets"
    ]];
  });
  if ([values containsObject:foldedFilename] || [values containsObject:stem]) {
    return YES;
  }
  return DSHHasSensitiveDottedPrefix(foldedFilename);
}

static BOOL DSHIsSensitivePathComponent(NSString *foldedComponent) {
  if ([DSHSensitiveDirectories() containsObject:foldedComponent] ||
      [foldedComponent hasPrefix:@".env"] ||
      [DSHSensitiveExtensions() containsObject:foldedComponent.pathExtension]) {
    return YES;
  }
  NSString *stem = [foldedComponent stringByDeletingPathExtension];
  static NSSet<NSString *> *sensitiveNames;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sensitiveNames = [NSSet setWithArray:@[
      @"credential", @"credentials", @"id_ed25519", @"id_rsa", @"secret",
      @"secrets"
    ]];
  });
  return [sensitiveNames containsObject:foldedComponent] ||
         [sensitiveNames containsObject:stem] ||
         DSHHasSensitiveDottedPrefix(foldedComponent);
}

static NSData *DSHSHA256(NSData *data) {
  uint8_t digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  return [NSData dataWithBytes:digest length:sizeof(digest)];
}

static NSData *DSHHMACSHA256(NSData *key, NSData *data) {
  uint8_t digest[CC_SHA256_DIGEST_LENGTH];
  CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, data.bytes, data.length, digest);
  return [NSData dataWithBytes:digest length:sizeof(digest)];
}

static NSData *DSHCursorAuthenticationData(NSData *payload, NSData *scope) {
  NSMutableData *authenticationData =
      [NSMutableData dataWithCapacity:payload.length + 1 + scope.length];
  [authenticationData appendData:payload];
  uint8_t hasScope = scope.length > 0 ? 1 : 0;
  [authenticationData appendBytes:&hasScope length:1];
  if (scope.length > 0) {
    [authenticationData appendData:scope];
  }
  return authenticationData;
}

static BOOL DSHConstantTimeEqual(const uint8_t *left,
                                 const uint8_t *right,
                                 NSUInteger length) {
  uint8_t difference = 0;
  for (NSUInteger index = 0; index < length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

static NSString *DSHBase64URLEncode(NSData *data) {
  NSString *encoded = [data base64EncodedStringWithOptions:0];
  encoded = [encoded stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
  encoded = [encoded stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
  return [encoded stringByReplacingOccurrencesOfString:@"=" withString:@""];
}

static NSData *DSHBase64URLDecode(NSString *encoded) {
  if (encoded.length != DSHCursorEncodedCharacters ||
      [encoded rangeOfCharacterFromSet:
                   [[NSCharacterSet characterSetWithCharactersInString:
                                        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"]
                       invertedSet]]
              .location != NSNotFound) {
    return nil;
  }
  NSString *base64 = [encoded stringByReplacingOccurrencesOfString:@"-" withString:@"+"];
  base64 = [base64 stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
  NSUInteger remainder = base64.length % 4;
  if (remainder == 1) {
    return nil;
  }
  if (remainder > 0) {
    base64 = [base64 stringByPaddingToLength:base64.length + (4 - remainder)
                                  withString:@"="
                             startingAtIndex:0];
  }
  NSData *decoded = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
  if (decoded == nil || ![DSHBase64URLEncode(decoded) isEqualToString:encoded]) {
    return nil;
  }
  return decoded;
}

static NSRegularExpression *DSHCompileExpression(
    NSString *pattern,
    NSRegularExpressionOptions options) {
  return [[NSRegularExpression alloc] initWithPattern:pattern
                                               options:options
                                                 error:nil];
}

static BOOL DSHStringHasMatch(NSString *string,
                              NSRegularExpression *expression) {
  return expression != nil &&
         [expression firstMatchInString:string
                                options:0
                                  range:NSMakeRange(0, string.length)] != nil;
}

static NSRegularExpression *DSHPrivateKeyExpression(void) {
  static NSRegularExpression *expression;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    expression = DSHCompileExpression(
        @"-----BEGIN(?: [A-Z0-9]+)* PRIVATE KEY-----|-----BEGIN PGP PRIVATE KEY BLOCK-----",
        NSRegularExpressionCaseInsensitive);
  });
  return expression;
}

static NSRegularExpression *DSHKnownTokenExpression(void) {
  static NSRegularExpression *expression;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    expression = DSHCompileExpression(
        @"(?:AKIA|ASIA)[A-Z0-9]{16}|gh[pousr]_[A-Za-z0-9]{20,255}|github_pat_[A-Za-z0-9_]{22,255}|glpat-[A-Za-z0-9_-]{20,255}|hf_[A-Za-z0-9]{20,255}|npm_[A-Za-z0-9]{20,255}|sk-[A-Za-z0-9_-]{16,255}|xox[baprs]-[A-Za-z0-9-]{10,255}|AIza[A-Za-z0-9_-]{20,255}",
        NSRegularExpressionCaseInsensitive);
  });
  return expression;
}

static NSRegularExpression *DSHJWTExpression(void) {
  static NSRegularExpression *expression;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    expression = DSHCompileExpression(
        @"(?:^|[^A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{5,}\\.[A-Za-z0-9_-]{5,}\\.[A-Za-z0-9_-]{5,}(?:$|[^A-Za-z0-9_-])",
        0);
  });
  return expression;
}

static NSRegularExpression *DSHPlaceholderCredentialExpression(void) {
  static NSRegularExpression *expression;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    expression = DSHCompileExpression(
        @"(?:change_me|changeme|dummy|example|nil|none|null|password|placeholder|redacted|secret|todo|token|test|undefined|xxxxx|<password>|<secret>|<token>|<api-key>|<api_key>|<your-password>|<your_password>|\\$\\{[a-z_][a-z0-9_]*\\}|\\{\\{[a-z_][a-z0-9_]*\\}\\}|process\\.env\\.[a-z_][a-z0-9_]*|(?:os\\.environ|env)\\[[\\\"'][a-z_][a-z0-9_]*[\\\"']\\]|getenv\\([\\\"'][a-z_][a-z0-9_]*[\\\"']\\))",
        NSRegularExpressionCaseInsensitive);
  });
  return expression;
}

static BOOL DSHCredentialValueRangeIsApproved(NSString *text, NSRange range) {
  static const NSUInteger maxPlaceholderCharacters = 512;
  if (range.length == 0) {
    return YES;
  }
  if (range.location == NSNotFound || range.length > maxPlaceholderCharacters ||
      NSMaxRange(range) > text.length) {
    return NO;
  }
  DSHRecordCredentialScanWork(range.length);
  NSTextCheckingResult *match =
      [DSHPlaceholderCredentialExpression()
          firstMatchInString:text
                     options:NSMatchingAnchored
                       range:range];
  return match != nil && NSEqualRanges(match.range, range);
}

static BOOL DSHIsLineBreak(unichar character) {
  return character == '\n' || character == '\r' || character == 0x2028 ||
         character == 0x2029;
}

static BOOL DSHIsHorizontalWhitespace(unichar character) {
  return character == ' ' || character == '\t' || character == '\f';
}

static BOOL DSHIsNonASCIIHorizontalWhitespace(unichar character) {
  return !DSHIsLineBreak(character) &&
         !DSHIsHorizontalWhitespace(character) &&
         [NSCharacterSet.whitespaceAndNewlineCharacterSet
             characterIsMember:character];
}

static NSUInteger DSHSkipHorizontalWhitespace(NSString *text,
                                               NSUInteger index) {
  while (index < text.length) {
    unichar character = [text characterAtIndex:index];
    DSHRecordCredentialScanWork(1);
    if (!DSHIsHorizontalWhitespace(character)) {
      break;
    }
    index++;
  }
  return index;
}

static BOOL DSHStartsNextJSONProperty(NSString *text, NSUInteger index) {
  if (index >= text.length) {
    return NO;
  }
  unichar quote = [text characterAtIndex:index];
  DSHRecordCredentialScanWork(1);
  if (quote != '\"') {
    return NO;
  }
  index++;
  NSUInteger keyCharacters = 0;
  while (index < text.length && keyCharacters <= 128) {
    unichar character = [text characterAtIndex:index++];
    DSHRecordCredentialScanWork(1);
    if (character == quote) {
      index = DSHSkipHorizontalWhitespace(text, index);
      if (index >= text.length) {
        return NO;
      }
      DSHRecordCredentialScanWork(1);
      return [text characterAtIndex:index] == ':';
    }
    if (character == '\\' && index < text.length) {
      index++;
      DSHRecordCredentialScanWork(1);
    }
    if (DSHIsLineBreak(character)) {
      return NO;
    }
    keyCharacters++;
  }
  return NO;
}

static BOOL DSHLineBreakStartsCredentialContinuation(NSString *text,
                                                      NSUInteger index,
                                                      BOOL jsonShaped,
                                                      BOOL afterJSONComma) {
  unichar next = 0;
  BOOL foundNext = NO;
  BOOL sawLineBreak = NO;
  BOOL horizontalWhitespaceAfterLastLineBreak = NO;
  while (index < text.length) {
    unichar character = [text characterAtIndex:index];
    DSHRecordCredentialScanWork(1);
    if (DSHIsLineBreak(character)) {
      sawLineBreak = YES;
      horizontalWhitespaceAfterLastLineBreak = NO;
      index++;
      continue;
    }
    if (DSHIsHorizontalWhitespace(character)) {
      horizontalWhitespaceAfterLastLineBreak = sawLineBreak;
      index++;
      continue;
    }
    if (DSHIsNonASCIIHorizontalWhitespace(character)) {
      return YES;
    }
    next = character;
    foundNext = YES;
    break;
  }
  if (!foundNext) {
    return NO;
  }
  if (jsonShaped) {
    if (next == '}' || next == ']') {
      return afterJSONComma;
    }
    if (next == '\"') {
      return !afterJSONComma || !DSHStartsNextJSONProperty(text, index);
    }
    if (next == ',') {
      if (afterJSONComma) {
        return YES;
      }
      NSUInteger afterComma = index + 1;
      while (afterComma < text.length) {
        unichar character = [text characterAtIndex:afterComma];
        DSHRecordCredentialScanWork(1);
        if (DSHIsHorizontalWhitespace(character) ||
            DSHIsLineBreak(character)) {
          afterComma++;
          continue;
        }
        if (DSHIsNonASCIIHorizontalWhitespace(character)) {
          return YES;
        }
        return character != '\"' ||
               !DSHStartsNextJSONProperty(text, afterComma);
      }
      return YES;
    }
    return YES;
  }
  if (horizontalWhitespaceAfterLastLineBreak && next != '#') {
    return YES;
  }
  if (!jsonShaped && (next == '\"' || next == '\'' || next == '`')) {
    return YES;
  }
  return next == '+' || next == '?' || next == '|' || next == '&' ||
         next == '\\' || next == '/' || next == '.' || next == ':' ||
         next == ';' || next == ',' || next == '}' || next == ']';
}

static BOOL DSHJSONClosingDelimitersExhaustAssignment(NSString *text,
                                                       NSUInteger index) {
  while (index < text.length) {
    unichar closing = [text characterAtIndex:index];
    DSHRecordCredentialScanWork(1);
    if (closing != '}' && closing != ']') {
      break;
    }
    index++;
  }
  index = DSHSkipHorizontalWhitespace(text, index);
  if (index >= text.length) {
    return YES;
  }
  unichar delimiter = [text characterAtIndex:index];
  DSHRecordCredentialScanWork(1);
  if (DSHIsNonASCIIHorizontalWhitespace(delimiter)) {
    return NO;
  }
  if (DSHIsLineBreak(delimiter)) {
    return !DSHLineBreakStartsCredentialContinuation(text, index, YES, NO);
  }
  if (delimiter != ',') {
    return NO;
  }
  index = DSHSkipHorizontalWhitespace(text, index + 1);
  if (index >= text.length) {
    return YES;
  }
  unichar next = [text characterAtIndex:index];
  DSHRecordCredentialScanWork(1);
  if (DSHIsNonASCIIHorizontalWhitespace(next)) {
    return NO;
  }
  return DSHIsLineBreak(next)
      ? !DSHLineBreakStartsCredentialContinuation(text, index, YES, YES)
      : DSHStartsNextJSONProperty(text, index);
}

static BOOL DSHCredentialTailIsSafe(NSString *text,
                                    NSUInteger tailStart,
                                    BOOL jsonShaped) {
  NSUInteger index = DSHSkipHorizontalWhitespace(text, tailStart);
  BOOL hadCommentBoundaryWhitespace = index > tailStart;
  if (index >= text.length) {
    return YES;
  }
  unichar delimiter = [text characterAtIndex:index];
  DSHRecordCredentialScanWork(1);
  if (DSHIsNonASCIIHorizontalWhitespace(delimiter)) {
    return NO;
  }
  if (DSHIsLineBreak(delimiter)) {
    return !DSHLineBreakStartsCredentialContinuation(text, index, jsonShaped,
                                                       NO);
  }
  if (delimiter == '#') {
    return hadCommentBoundaryWhitespace;
  }
  if (!jsonShaped) {
    return NO;
  }
  if (delimiter == '}' || delimiter == ']') {
    return DSHJSONClosingDelimitersExhaustAssignment(text, index);
  }
  if (delimiter != ',') {
    return NO;
  }
  index = DSHSkipHorizontalWhitespace(text, index + 1);
  if (index >= text.length) {
    return YES;
  }
  unichar next = [text characterAtIndex:index];
  DSHRecordCredentialScanWork(1);
  if (DSHIsNonASCIIHorizontalWhitespace(next)) {
    return NO;
  }
  if (DSHIsLineBreak(next)) {
    return !DSHLineBreakStartsCredentialContinuation(text, index, YES, YES);
  }
  if (next == '}' || next == ']') {
    return DSHJSONClosingDelimitersExhaustAssignment(text, index);
  }
  return DSHStartsNextJSONProperty(text, index);
}

static BOOL DSHCredentialRHSIsApprovedPlaceholder(NSString *text,
                                                   NSUInteger rhsStart,
                                                   BOOL jsonShaped) {
  if (rhsStart >= text.length) {
    return NO;
  }
  unichar first = [text characterAtIndex:rhsStart];
  DSHRecordCredentialScanWork(1);
  if (DSHIsLineBreak(first) || DSHIsNonASCIIHorizontalWhitespace(first)) {
    return NO;
  }

  static const NSUInteger maxPlaceholderCharacters = 512;
  NSUInteger tailStart = rhsStart;
  if (first == '\"' || first == '\'') {
    unichar quote = first;
    NSUInteger valueStart = rhsStart + 1;
    NSUInteger index = valueStart;
    BOOL closed = NO;
    while (index < text.length &&
           index - valueStart <= maxPlaceholderCharacters) {
      unichar character = [text characterAtIndex:index++];
      DSHRecordCredentialScanWork(1);
      if (DSHIsLineBreak(character)) {
        return NO;
      }
      if (character == '\\' && index < text.length) {
        index++;
        DSHRecordCredentialScanWork(1);
        continue;
      }
      if (character == quote) {
        tailStart = index;
        closed = YES;
        break;
      }
    }
    if (!closed) {
      return NO;
    }
    NSRange valueRange = NSMakeRange(valueStart, tailStart - valueStart - 1);
    if (!DSHCredentialValueRangeIsApproved(text, valueRange)) {
      return NO;
    }
  } else {
    NSRange searchRange = NSMakeRange(
        rhsStart, MIN(maxPlaceholderCharacters, text.length - rhsStart));
    NSTextCheckingResult *match =
        [DSHPlaceholderCredentialExpression()
            firstMatchInString:text
                       options:NSMatchingAnchored
                         range:searchRange];
    if (match == nil || match.range.location != rhsStart) {
      return NO;
    }
    DSHRecordCredentialScanWork(match.range.length);
    tailStart = NSMaxRange(match.range);
  }
  return DSHCredentialTailIsSafe(text, tailStart, jsonShaped);
}

typedef struct {
  BOOL valid;
  BOOL closing;
  BOOL selfClosing;
  NSRange qualifiedName;
  NSRange localName;
  NSRange attributes;
  NSUInteger nextIndex;
} DSHXMLTag;

typedef struct {
  BOOL valid;
  NSRange content;
  NSUInteger nextIndex;
} DSHQuotedToken;

static unichar DSHStructuredCharacterAtIndex(NSString *text,
                                              NSUInteger index) {
  DSHRecordCredentialScanWork(1);
  return [text characterAtIndex:index];
}

static BOOL DSHIsXMLWhitespace(unichar character) {
  return character == ' ' || character == '\t' || character == '\r' ||
         character == '\n';
}

static BOOL DSHIsXMLNameCharacter(unichar character) {
  return (character >= 'a' && character <= 'z') ||
         (character >= 'A' && character <= 'Z') ||
         (character >= '0' && character <= '9') || character == '_' ||
         character == '-' || character == ':' || character == '.' ||
         character > 0x7f;
}

static int DSHASCIIHexValue(unichar character) {
  if (character >= '0' && character <= '9') {
    return (int)(character - '0');
  }
  if (character >= 'a' && character <= 'f') {
    return (int)(character - 'a' + 10);
  }
  if (character >= 'A' && character <= 'F') {
    return (int)(character - 'A' + 10);
  }
  return -1;
}

static BOOL DSHDecodeXMLCharacterReference(NSString *text,
                                            NSUInteger *index,
                                            NSUInteger end,
                                            unichar *decodedCharacter) {
  NSUInteger cursor = *index;
  if (cursor >= end) {
    return NO;
  }
  char entity[9] = {0};
  NSUInteger entityLength = 0;
  while (cursor < end && entityLength + 1 < sizeof(entity)) {
    unichar character = DSHStructuredCharacterAtIndex(text, cursor++);
    if (character == ';') {
      entity[entityLength] = '\0';
      unsigned value = 0;
      if (entityLength >= 2 && entity[0] == '#') {
        NSUInteger digitIndex = 1;
        int radix = 10;
        if (digitIndex < entityLength &&
            (entity[digitIndex] == 'x' || entity[digitIndex] == 'X')) {
          radix = 16;
          digitIndex++;
        }
        if (digitIndex >= entityLength) {
          return NO;
        }
        for (; digitIndex < entityLength; digitIndex++) {
          int digit = radix == 16 ? DSHASCIIHexValue(entity[digitIndex])
                                  : (entity[digitIndex] >= '0' &&
                                             entity[digitIndex] <= '9'
                                         ? entity[digitIndex] - '0'
                                         : -1);
          if (digit < 0 || value > 0x7f / (unsigned)radix) {
            return NO;
          }
          value = value * (unsigned)radix + (unsigned)digit;
        }
      } else if (strcmp(entity, "amp") == 0) {
        value = '&';
      } else if (strcmp(entity, "quot") == 0) {
        value = '\"';
      } else if (strcmp(entity, "apos") == 0) {
        value = '\'';
      } else if (strcmp(entity, "lt") == 0) {
        value = '<';
      } else if (strcmp(entity, "gt") == 0) {
        value = '>';
      } else {
        return NO;
      }
      if (value > 0x7f) {
        return NO;
      }
      *decodedCharacter = (unichar)value;
      *index = cursor;
      return YES;
    }
    if (character > 0x7f) {
      return NO;
    }
    entity[entityLength++] = (char)character;
  }
  return NO;
}

static BOOL DSHCredentialKeyBufferMatches(const char *key, NSUInteger length) {
  // Keep this vocabulary synchronized across scalar identifiers, JSON/JS
  // constant keys, XML local names, and plist/property key values. Matching is
  // exact or scoped by '_' / '.'; arbitrary substring matches are forbidden.
  static const char *values[] = {
    "password", "passwd", "pwd", "secret", "token", "api_key",
    "access_key", "client_secret", "private_key", "credential", "apikey",
    "accesskey", "clientsecret", "privatekey",
  };
  for (const char *value : values) {
    NSUInteger valueLength = strlen(value);
    if (length == valueLength && memcmp(key, value, valueLength) == 0) {
      return YES;
    }
    if (length > valueLength + 1 &&
        (key[length - valueLength - 1] == '_' ||
         key[length - valueLength - 1] == '.') &&
        memcmp(key + length - valueLength, value, valueLength) == 0) {
      return YES;
    }
  }
  return NO;
}

static BOOL DSHCanonicalCredentialKeyMatches(NSString *text,
                                              NSRange range,
                                              BOOL decodeJSONEscapes,
                                              BOOL decodeXMLEntities) {
  if (range.location == NSNotFound || NSMaxRange(range) > text.length ||
      range.length > 128) {
    return NO;
  }
  char canonical[129] = {0};
  NSUInteger length = 0;
  NSUInteger index = range.location;
  NSUInteger end = NSMaxRange(range);
  while (index < end) {
    unichar character = DSHStructuredCharacterAtIndex(text, index++);
    if (decodeJSONEscapes && character == '\\') {
      if (index >= end) {
        return NO;
      }
      unichar escaped = DSHStructuredCharacterAtIndex(text, index++);
      if (escaped == 'u') {
        if (end - index < 4) {
          return NO;
        }
        unsigned value = 0;
        for (NSUInteger digitIndex = 0; digitIndex < 4; digitIndex++) {
          int digit = DSHASCIIHexValue(
              DSHStructuredCharacterAtIndex(text, index++));
          if (digit < 0) {
            return NO;
          }
          value = (value << 4) | (unsigned)digit;
        }
        if (value > 0x7f) {
          return NO;
        }
        character = (unichar)value;
      } else if (escaped == 'x') {
        if (end - index < 2) {
          return NO;
        }
        int high = DSHASCIIHexValue(
            DSHStructuredCharacterAtIndex(text, index++));
        int low = DSHASCIIHexValue(
            DSHStructuredCharacterAtIndex(text, index++));
        if (high < 0 || low < 0) {
          return NO;
        }
        character = (unichar)((high << 4) | low);
      } else if (escaped == '\"' || escaped == '\'' || escaped == '`' ||
                 escaped == '\\' || escaped == '/') {
        character = escaped;
      } else {
        return NO;
      }
    }
    if (decodeXMLEntities && character == '&') {
      if (!DSHDecodeXMLCharacterReference(text, &index, end, &character)) {
        return NO;
      }
    }
    if (character >= 'A' && character <= 'Z') {
      character = (unichar)(character - 'A' + 'a');
    }
    if (character == '-') {
      character = '_';
    }
    if (character > 0x7f || length + 1 >= sizeof(canonical)) {
      return NO;
    }
    canonical[length++] = (char)character;
  }
  canonical[length] = '\0';
  return DSHCredentialKeyBufferMatches(canonical, length);
}

static BOOL DSHRangeEqualsASCII(NSString *text,
                                NSRange range,
                                const char *literal) {
  NSUInteger literalLength = strlen(literal);
  if (range.location == NSNotFound || range.length != literalLength ||
      NSMaxRange(range) > text.length) {
    return NO;
  }
  for (NSUInteger index = 0; index < range.length; index++) {
    unichar character =
        DSHStructuredCharacterAtIndex(text, range.location + index);
    if (character >= 'A' && character <= 'Z') {
      character = (unichar)(character - 'A' + 'a');
    }
    if (character != (unsigned char)literal[index]) {
      return NO;
    }
  }
  return YES;
}

static BOOL DSHRangesEqualASCII(NSString *text, NSRange left, NSRange right) {
  if (left.location == NSNotFound || right.location == NSNotFound ||
      left.length != right.length || NSMaxRange(left) > text.length ||
      NSMaxRange(right) > text.length) {
    return NO;
  }
  for (NSUInteger index = 0; index < left.length; index++) {
    unichar leftCharacter =
        DSHStructuredCharacterAtIndex(text, left.location + index);
    unichar rightCharacter =
        DSHStructuredCharacterAtIndex(text, right.location + index);
    if (leftCharacter >= 'A' && leftCharacter <= 'Z') {
      leftCharacter = (unichar)(leftCharacter - 'A' + 'a');
    }
    if (rightCharacter >= 'A' && rightCharacter <= 'Z') {
      rightCharacter = (unichar)(rightCharacter - 'A' + 'a');
    }
    if (leftCharacter != rightCharacter) {
      return NO;
    }
  }
  return YES;
}

static DSHXMLTag DSHParseXMLTag(NSString *text, NSUInteger start) {
  DSHXMLTag tag = {};
  tag.qualifiedName = NSMakeRange(NSNotFound, 0);
  tag.localName = NSMakeRange(NSNotFound, 0);
  tag.attributes = NSMakeRange(NSNotFound, 0);
  tag.nextIndex = MIN(text.length, start + 1);
  if (start >= text.length ||
      DSHStructuredCharacterAtIndex(text, start) != '<') {
    return tag;
  }
  NSUInteger index = start + 1;
  while (index < text.length &&
         DSHIsHorizontalWhitespace(
             DSHStructuredCharacterAtIndex(text, index))) {
    index++;
  }
  if (index < text.length &&
      DSHStructuredCharacterAtIndex(text, index) == '/') {
    tag.closing = YES;
    index++;
  }
  if (index >= text.length) {
    tag.nextIndex = text.length;
    return tag;
  }
  unichar first = DSHStructuredCharacterAtIndex(text, index);
  if (first == '!' || first == '?' || !DSHIsXMLNameCharacter(first)) {
    return tag;
  }
  NSUInteger nameStart = index;
  NSUInteger localStart = index;
  while (index < text.length) {
    unichar character = DSHStructuredCharacterAtIndex(text, index);
    if (!DSHIsXMLNameCharacter(character)) {
      break;
    }
    if (character == ':') {
      localStart = index + 1;
    }
    index++;
    if (index - nameStart > 128) {
      tag.nextIndex = index;
      return tag;
    }
  }
  if (index == nameStart || localStart >= index) {
    tag.nextIndex = MAX(tag.nextIndex, index);
    return tag;
  }
  tag.qualifiedName = NSMakeRange(nameStart, index - nameStart);
  tag.localName = NSMakeRange(localStart, index - localStart);
  NSUInteger attributesStart = index;

  unichar quote = 0;
  unichar lastNonWhitespace = 0;
  while (index < text.length) {
    unichar character = DSHStructuredCharacterAtIndex(text, index);
    if (quote != 0) {
      if (character == quote) {
        quote = 0;
      }
      index++;
      continue;
    }
    if (character == '\"' || character == '\'') {
      quote = character;
      index++;
      continue;
    }
    if (character == '<') {
      tag.nextIndex = index;
      return tag;
    }
    if (character == '>') {
      tag.selfClosing = !tag.closing && lastNonWhitespace == '/';
      tag.attributes = NSMakeRange(attributesStart, index - attributesStart);
      tag.nextIndex = index + 1;
      tag.valid = YES;
      return tag;
    }
    if (!DSHIsXMLWhitespace(character)) {
      lastNonWhitespace = character;
    }
    index++;
  }
  tag.nextIndex = text.length;
  return tag;
}

typedef NS_ENUM(NSUInteger, DSHXMLAttributeResult) {
  DSHXMLAttributeNotFound = 0,
  DSHXMLAttributeFound = 1,
  DSHXMLAttributeMalformed = 2,
};

static DSHXMLAttributeResult DSHFindXMLAttribute(NSString *text,
                                                 DSHXMLTag tag,
                                                 const char *attributeName,
                                                 NSRange *valueRange) {
  if (!tag.valid || tag.attributes.location == NSNotFound ||
      NSMaxRange(tag.attributes) > text.length) {
    return DSHXMLAttributeMalformed;
  }
  NSUInteger cursor = tag.attributes.location;
  NSUInteger end = NSMaxRange(tag.attributes);
  BOOL found = NO;
  NSRange foundValue = NSMakeRange(NSNotFound, 0);
  while (cursor < end) {
    while (cursor < end &&
           DSHIsXMLWhitespace(
               DSHStructuredCharacterAtIndex(text, cursor))) {
      cursor++;
    }
    if (cursor >= end) {
      break;
    }
    unichar first = DSHStructuredCharacterAtIndex(text, cursor);
    if (first == '/') {
      break;
    }
    NSUInteger nameStart = cursor;
    NSUInteger localStart = cursor;
    while (cursor < end) {
      unichar character = DSHStructuredCharacterAtIndex(text, cursor);
      if (!DSHIsXMLNameCharacter(character)) {
        break;
      }
      if (character == ':') {
        localStart = cursor + 1;
      }
      cursor++;
      if (cursor - nameStart > 128) {
        return DSHXMLAttributeMalformed;
      }
    }
    if (cursor == nameStart || localStart >= cursor) {
      return DSHXMLAttributeMalformed;
    }
    NSRange localName = NSMakeRange(localStart, cursor - localStart);
    while (cursor < end &&
           DSHIsXMLWhitespace(
               DSHStructuredCharacterAtIndex(text, cursor))) {
      cursor++;
    }
    if (cursor >= end ||
        DSHStructuredCharacterAtIndex(text, cursor) != '=') {
      return DSHXMLAttributeMalformed;
    }
    cursor++;
    while (cursor < end &&
           DSHIsXMLWhitespace(
               DSHStructuredCharacterAtIndex(text, cursor))) {
      cursor++;
    }
    if (cursor >= end) {
      return DSHXMLAttributeMalformed;
    }
    unichar quote = DSHStructuredCharacterAtIndex(text, cursor++);
    if (quote != '\"' && quote != '\'') {
      return DSHXMLAttributeMalformed;
    }
    NSUInteger valueStart = cursor;
    while (cursor < end &&
           DSHStructuredCharacterAtIndex(text, cursor) != quote) {
      cursor++;
    }
    if (cursor >= end) {
      return DSHXMLAttributeMalformed;
    }
    NSRange parsedValue = NSMakeRange(valueStart, cursor - valueStart);
    cursor++;
    if (DSHRangeEqualsASCII(text, localName, attributeName)) {
      if (found) {
        return DSHXMLAttributeMalformed;
      }
      found = YES;
      foundValue = parsedValue;
    }
  }
  if (found && valueRange != nullptr) {
    *valueRange = foundValue;
  }
  return found ? DSHXMLAttributeFound : DSHXMLAttributeNotFound;
}

static NSUInteger DSHSkipXMLWhitespace(NSString *text, NSUInteger index) {
  while (index < text.length) {
    unichar character = DSHStructuredCharacterAtIndex(text, index);
    if (!DSHIsXMLWhitespace(character)) {
      break;
    }
    index++;
  }
  return index;
}

static NSRange DSHRangeByTrimmingXMLWhitespace(NSString *text,
                                                NSRange range) {
  NSUInteger start = range.location;
  NSUInteger end = NSMaxRange(range);
  while (start < end &&
         DSHIsXMLWhitespace(DSHStructuredCharacterAtIndex(text, start))) {
    start++;
  }
  while (end > start &&
         DSHIsXMLWhitespace(DSHStructuredCharacterAtIndex(text, end - 1))) {
    end--;
  }
  return NSMakeRange(start, end - start);
}

static BOOL DSHTextHasASCIILiteralAtIndex(NSString *text,
                                          NSUInteger index,
                                          const char *literal) {
  NSUInteger length = strlen(literal);
  if (index > text.length || length > text.length - index) {
    return NO;
  }
  for (NSUInteger offset = 0; offset < length; offset++) {
    if (DSHStructuredCharacterAtIndex(text, index + offset) !=
        (unsigned char)literal[offset]) {
      return NO;
    }
  }
  return YES;
}

static BOOL DSHParseSimpleXMLElement(NSString *text,
                                     DSHXMLTag openingTag,
                                     NSRange *valueRange,
                                     NSUInteger *nextIndex) {
  if (!openingTag.valid || openingTag.closing) {
    return NO;
  }
  if (openingTag.selfClosing) {
    if (valueRange != nullptr) {
      *valueRange = NSMakeRange(openingTag.nextIndex, 0);
    }
    if (nextIndex != nullptr) {
      *nextIndex = openingTag.nextIndex;
    }
    return YES;
  }

  NSUInteger contentStart = openingTag.nextIndex;
  NSUInteger cursor = DSHSkipXMLWhitespace(text, contentStart);
  NSRange parsedValue = NSMakeRange(contentStart, 0);
  if (DSHTextHasASCIILiteralAtIndex(text, cursor, "<![CDATA[")) {
    NSUInteger cdataStart = cursor + strlen("<![CDATA[");
    NSUInteger cdataCursor = cdataStart;
    NSUInteger cdataEnd = NSNotFound;
    while (cdataCursor < text.length) {
      unichar character =
          DSHStructuredCharacterAtIndex(text, cdataCursor);
      if (character == ']' && cdataCursor + 2 < text.length &&
          DSHStructuredCharacterAtIndex(text, cdataCursor + 1) == ']' &&
          DSHStructuredCharacterAtIndex(text, cdataCursor + 2) == '>') {
        cdataEnd = cdataCursor;
        cdataCursor += 3;
        break;
      }
      cdataCursor++;
    }
    if (cdataEnd == NSNotFound) {
      return NO;
    }
    parsedValue = NSMakeRange(cdataStart, cdataEnd - cdataStart);
    cursor = DSHSkipXMLWhitespace(text, cdataCursor);
  } else {
    cursor = contentStart;
    while (cursor < text.length &&
           DSHStructuredCharacterAtIndex(text, cursor) != '<') {
      cursor++;
    }
    if (cursor >= text.length) {
      return NO;
    }
    parsedValue = NSMakeRange(contentStart, cursor - contentStart);
  }

  DSHXMLTag closingTag = DSHParseXMLTag(text, cursor);
  if (!closingTag.valid || !closingTag.closing || closingTag.selfClosing ||
      !DSHRangesEqualASCII(text, openingTag.qualifiedName,
                           closingTag.qualifiedName)) {
    return NO;
  }
  if (valueRange != nullptr) {
    *valueRange = DSHRangeByTrimmingXMLWhitespace(text, parsedValue);
  }
  if (nextIndex != nullptr) {
    *nextIndex = closingTag.nextIndex;
  }
  return YES;
}

static DSHQuotedToken DSHParseQuotedToken(NSString *text, NSUInteger start) {
  DSHQuotedToken token = {};
  token.content = NSMakeRange(NSNotFound, 0);
  token.nextIndex = MIN(text.length, start + 1);
  if (start >= text.length) {
    return token;
  }
  unichar quote = DSHStructuredCharacterAtIndex(text, start);
  if (quote != '\"' && quote != '\'' && quote != '`') {
    return token;
  }
  NSUInteger index = start + 1;
  NSUInteger contentStart = index;
  BOOL overlong = NO;
  while (index < text.length) {
    unichar character = DSHStructuredCharacterAtIndex(text, index++);
    if (DSHIsLineBreak(character)) {
      token.nextIndex = index;
      return token;
    }
    if (character == '\\' && index < text.length) {
      index++;
      DSHRecordCredentialScanWork(1);
      overlong |= index - contentStart > 128;
      continue;
    }
    if (character == quote) {
      token.content = NSMakeRange(contentStart, index - contentStart - 1);
      token.nextIndex = index;
      token.valid = !overlong && token.content.length <= 128;
      return token;
    }
    overlong |= index - contentStart > 128;
  }
  token.nextIndex = text.length;
  return token;
}

static BOOL DSHQuotedTokenHasJSONBoundary(NSString *text,
                                          NSUInteger quoteIndex) {
  NSUInteger index = quoteIndex;
  NSUInteger scanned = 0;
  while (index > 0) {
    if (scanned++ >= 256) {
      return NO;
    }
    unichar previous = DSHStructuredCharacterAtIndex(text, index - 1);
    if (DSHIsHorizontalWhitespace(previous) || DSHIsLineBreak(previous)) {
      index--;
      continue;
    }
    return previous == '{' || previous == ',';
  }
  return YES;
}

static NSUInteger DSHSkipAssignmentWhitespace(NSString *text,
                                               NSUInteger index,
                                               BOOL *ambiguous) {
  while (index < text.length) {
    unichar character = DSHStructuredCharacterAtIndex(text, index);
    if (DSHIsHorizontalWhitespace(character)) {
      index++;
      continue;
    }
    if (DSHIsLineBreak(character) ||
        DSHIsNonASCIIHorizontalWhitespace(character)) {
      if (ambiguous != nullptr) {
        *ambiguous = YES;
      }
      index++;
      continue;
    }
    break;
  }
  return index;
}

static BOOL DSHRangeVisiblyContainsCredentialKey(NSString *text,
                                                  NSRange range) {
  NSUInteger index = range.location;
  NSUInteger end = NSMaxRange(range);
  while (index < end) {
    unichar character = DSHStructuredCharacterAtIndex(text, index);
    BOOL identifierCharacter =
        (character >= 'a' && character <= 'z') ||
        (character >= 'A' && character <= 'Z') ||
        (character >= '0' && character <= '9') || character == '_' ||
        character == '-' || character == '.';
    if (!identifierCharacter) {
      index++;
      continue;
    }
    NSUInteger start = index++;
    while (index < end) {
      character = DSHStructuredCharacterAtIndex(text, index);
      identifierCharacter =
          (character >= 'a' && character <= 'z') ||
          (character >= 'A' && character <= 'Z') ||
          (character >= '0' && character <= '9') || character == '_' ||
          character == '-' || character == '.';
      if (!identifierCharacter) {
        break;
      }
      index++;
    }
    NSUInteger candidateEnd = index;
    while (candidateEnd > start) {
      unichar trailing =
          DSHStructuredCharacterAtIndex(text, candidateEnd - 1);
      if (trailing != '_' && trailing != '-' && trailing != '.') {
        break;
      }
      candidateEnd--;
    }
    NSRange candidateRange = NSMakeRange(start, candidateEnd - start);
    if (candidateRange.length > 128) {
      candidateRange.location = NSMaxRange(candidateRange) - 128;
      candidateRange.length = 128;
    }
    if (DSHCanonicalCredentialKeyMatches(text, candidateRange, NO, NO)) {
      return YES;
    }
  }
  return NO;
}

static BOOL DSHRangeContainsTemplateInterpolation(NSString *text,
                                                   NSRange range) {
  NSUInteger end = NSMaxRange(range);
  for (NSUInteger index = range.location; index + 1 < end; index++) {
    if (DSHStructuredCharacterAtIndex(text, index) == '$' &&
        DSHStructuredCharacterAtIndex(text, index + 1) == '{') {
      return YES;
    }
  }
  return NO;
}

static NSUInteger DSHSkipJSBracketTriviaForward(NSString *text,
                                                 NSUInteger index,
                                                 BOOL *ambiguous,
                                                 BOOL *valid) {
  while (index < text.length) {
    unichar character = DSHStructuredCharacterAtIndex(text, index);
    if (DSHIsHorizontalWhitespace(character)) {
      index++;
      continue;
    }
    if (DSHIsLineBreak(character) ||
        DSHIsNonASCIIHorizontalWhitespace(character)) {
      if (ambiguous != nullptr) {
        *ambiguous = YES;
      }
      index++;
      continue;
    }
    if (character == '/' && index + 1 < text.length) {
      unichar following = DSHStructuredCharacterAtIndex(text, index + 1);
      if (following == '*') {
        NSUInteger cursor = index + 2;
        NSUInteger scanned = 0;
        BOOL overlong = NO;
        BOOL closed = NO;
        while (cursor + 1 < text.length) {
          scanned++;
          overlong |= scanned > 256;
          if (DSHStructuredCharacterAtIndex(text, cursor) == '*' &&
              DSHStructuredCharacterAtIndex(text, cursor + 1) == '/') {
            index = cursor + 2;
            closed = YES;
            break;
          }
          cursor++;
        }
        if (!closed) {
          if (valid != nullptr) {
            *valid = NO;
          }
          return text.length;
        }
        if (overlong && ambiguous != nullptr) {
          *ambiguous = YES;
        }
        continue;
      }
      if (following == '/') {
        NSUInteger cursor = index + 2;
        while (cursor < text.length &&
               !DSHIsLineBreak(
                   DSHStructuredCharacterAtIndex(text, cursor))) {
          cursor++;
        }
        if (ambiguous != nullptr) {
          *ambiguous = YES;
        }
        index = cursor;
        continue;
      }
    }
    break;
  }
  return index;
}

static NSUInteger DSHJSAssignmentOperatorLength(NSString *text,
                                                 NSUInteger index) {
  if (index >= text.length) {
    return 0;
  }
  unichar first = DSHStructuredCharacterAtIndex(text, index);
  if (first == '=') {
    if (index + 1 < text.length) {
      unichar following = DSHStructuredCharacterAtIndex(text, index + 1);
      if (following == '=' || following == '>') {
        return 0;
      }
    }
    return 1;
  }
  if (index + 2 < text.length &&
      ((first == '|' &&
        DSHStructuredCharacterAtIndex(text, index + 1) == '|') ||
       (first == '&' &&
        DSHStructuredCharacterAtIndex(text, index + 1) == '&') ||
       (first == '?' &&
        DSHStructuredCharacterAtIndex(text, index + 1) == '?')) &&
      DSHStructuredCharacterAtIndex(text, index + 2) == '=') {
    return 3;
  }
  if (index + 1 < text.length &&
      (first == '+' || first == '-' || first == '*' || first == '/' ||
       first == '%' || first == '|' || first == '&' || first == '^') &&
      DSHStructuredCharacterAtIndex(text, index + 1) == '=') {
    return 2;
  }
  return 0;
}

static BOOL DSHIsCredentialTokenCharacter(unichar character) {
  return (character >= 'a' && character <= 'z') ||
         (character >= 'A' && character <= 'Z') ||
         (character >= '0' && character <= '9') || character == '_' ||
         character == '-' || character == '.';
}

static BOOL DSHBracketExpressionIsUnsafe(NSString *text,
                                         NSUInteger openingBracket,
                                         NSUInteger *nextIndex) {
  BOOL ambiguous = NO;
  BOOL validTrivia = YES;
  NSUInteger cursor = DSHSkipJSBracketTriviaForward(
      text, openingBracket + 1, &ambiguous, &validTrivia);
  if (!validTrivia) {
    if (nextIndex != nullptr) {
      *nextIndex = text.length;
    }
    return NO;
  }

  BOOL visibleCredential = NO;
  BOOL constantCredential = NO;
  NSUInteger significantComponents = 0;
  while (cursor < text.length) {
    cursor = DSHSkipJSBracketTriviaForward(text, cursor, &ambiguous,
                                            &validTrivia);
    if (!validTrivia) {
      if (nextIndex != nullptr) {
        *nextIndex = text.length;
      }
      return NO;
    }
    if (cursor >= text.length) {
      if (nextIndex != nullptr) {
        *nextIndex = text.length;
      }
      return visibleCredential;
    }
    unichar character = DSHStructuredCharacterAtIndex(text, cursor);
    if (character == ']') {
      break;
    }
    if (character == '\"' || character == '\'' || character == '`') {
      DSHQuotedToken token = DSHParseQuotedToken(text, cursor);
      if (token.content.location == NSNotFound) {
        if (nextIndex != nullptr) {
          *nextIndex = MAX(cursor + 1, token.nextIndex);
        }
        return visibleCredential;
      }
      if (!token.valid) {
        visibleCredential |=
            DSHRangeVisiblyContainsCredentialKey(text, token.content);
        significantComponents++;
        constantCredential = NO;
        cursor = token.nextIndex;
        continue;
      }
      BOOL constantToken =
          DSHCanonicalCredentialKeyMatches(text, token.content, YES, NO);
      BOOL dynamicToken =
          character == '`' &&
          DSHRangeContainsTemplateInterpolation(text, token.content) &&
          DSHRangeVisiblyContainsCredentialKey(text, token.content);
      visibleCredential |= constantToken || dynamicToken;
      significantComponents++;
      constantCredential =
          significantComponents == 1 && constantToken && !dynamicToken;
      cursor = token.nextIndex;
      continue;
    }
    if (DSHIsCredentialTokenCharacter(character)) {
      NSUInteger tokenStart = cursor++;
      while (cursor < text.length &&
             DSHIsCredentialTokenCharacter(
                 DSHStructuredCharacterAtIndex(text, cursor))) {
        cursor++;
      }
      NSRange tokenRange = NSMakeRange(tokenStart, cursor - tokenStart);
      visibleCredential |=
          DSHCanonicalCredentialKeyMatches(text, tokenRange, NO, NO) ||
          DSHRangeVisiblyContainsCredentialKey(text, tokenRange);
      significantComponents++;
      constantCredential = NO;
      continue;
    }
    significantComponents++;
    constantCredential = NO;
    cursor++;
  }

  if (cursor >= text.length ||
      DSHStructuredCharacterAtIndex(text, cursor) != ']') {
    if (nextIndex != nullptr) {
      *nextIndex = MAX(openingBracket + 1, cursor);
    }
    return visibleCredential;
  }
  if (nextIndex != nullptr) {
    *nextIndex = cursor + 1;
  }

  NSUInteger assignment = DSHSkipJSBracketTriviaForward(
      text, cursor + 1, &ambiguous, &validTrivia);
  if (!validTrivia) {
    return NO;
  }
  NSUInteger operatorLength =
      DSHJSAssignmentOperatorLength(text, assignment);
  if (operatorLength == 0 || !visibleCredential) {
    return NO;
  }
  if (ambiguous || !constantCredential) {
    return YES;
  }
  NSUInteger rhsStart = DSHSkipAssignmentWhitespace(
      text, assignment + operatorLength, &ambiguous);
  return ambiguous ||
         !DSHCredentialRHSIsApprovedPlaceholder(text, rhsStart, NO);
}

static BOOL DSHQuotedJSONCredentialKeyIsUnsafe(NSString *text,
                                                NSUInteger quoteIndex,
                                                DSHQuotedToken token) {
  if (!token.valid ||
      DSHStructuredCharacterAtIndex(text, quoteIndex) != '\"' ||
      !DSHCanonicalCredentialKeyMatches(text, token.content, YES, NO)) {
    return NO;
  }
  BOOL ambiguous = NO;
  NSUInteger separatorIndex =
      DSHSkipAssignmentWhitespace(text, token.nextIndex, &ambiguous);
  if (separatorIndex >= text.length ||
      DSHStructuredCharacterAtIndex(text, separatorIndex) != ':' ||
      !DSHQuotedTokenHasJSONBoundary(text, quoteIndex)) {
    return NO;
  }
  NSUInteger rhsStart =
      DSHSkipAssignmentWhitespace(text, separatorIndex + 1, &ambiguous);
  return ambiguous ||
         !DSHCredentialRHSIsApprovedPlaceholder(text, rhsStart, YES);
}

static BOOL DSHHasCredentialAssignment(NSString *text) {
  NSUInteger index = 0;
  while (index < text.length) {
    unichar character = DSHStructuredCharacterAtIndex(text, index);
    if (!DSHIsCredentialTokenCharacter(character)) {
      index++;
      continue;
    }
    NSUInteger tokenStart = index++;
    while (index < text.length &&
           DSHIsCredentialTokenCharacter(
               DSHStructuredCharacterAtIndex(text, index))) {
      index++;
    }
    NSRange tokenRange = NSMakeRange(tokenStart, index - tokenStart);
    NSRange boundedTokenRange = tokenRange;
    if (boundedTokenRange.length > 128) {
      boundedTokenRange.location = NSMaxRange(boundedTokenRange) - 128;
      boundedTokenRange.length = 128;
    }
    if (!DSHCanonicalCredentialKeyMatches(text, boundedTokenRange, NO, NO)) {
      continue;
    }

    unichar quote = 0;
    NSUInteger separatorStart = index;
    if (tokenStart > 0 && index < text.length) {
      unichar opening =
          DSHStructuredCharacterAtIndex(text, tokenStart - 1);
      unichar closing = DSHStructuredCharacterAtIndex(text, index);
      if ((opening == '\"' || opening == '\'') && closing == opening) {
        quote = opening;
        separatorStart++;
      }
    }
    BOOL ambiguous = NO;
    NSUInteger separator =
        DSHSkipAssignmentWhitespace(text, separatorStart, &ambiguous);
    if (separator >= text.length) {
      continue;
    }
    unichar separatorCharacter =
        DSHStructuredCharacterAtIndex(text, separator);
    if (separatorCharacter != ':' && separatorCharacter != '=') {
      continue;
    }
    BOOL jsonShaped =
        quote == '\"' && separatorCharacter == ':' &&
        DSHQuotedTokenHasJSONBoundary(text, tokenStart - 1);
    NSUInteger rhsStart =
        DSHSkipAssignmentWhitespace(text, separator + 1, &ambiguous);
    if (ambiguous ||
        !DSHCredentialRHSIsApprovedPlaceholder(text, rhsStart, jsonShaped)) {
      return YES;
    }
  }
  return NO;
}

static BOOL DSHHasUnsafeStructuredCredential(NSString *text) {
  NSUInteger index = 0;
  while (index < text.length) {
    unichar character = DSHStructuredCharacterAtIndex(text, index);
    if (character == '<') {
      DSHXMLTag tag = DSHParseXMLTag(text, index);
      if (!tag.valid) {
        index = MAX(index + 1, tag.nextIndex);
        continue;
      }
      if (!tag.closing &&
          DSHCanonicalCredentialKeyMatches(text, tag.localName, NO, NO)) {
        NSRange attributeValue = NSMakeRange(NSNotFound, 0);
        DSHXMLAttributeResult attributeResult =
            DSHFindXMLAttribute(text, tag, "value", &attributeValue);
        if (attributeResult == DSHXMLAttributeMalformed ||
            (attributeResult == DSHXMLAttributeFound &&
             !DSHCredentialValueRangeIsApproved(
                 text,
                 DSHRangeByTrimmingXMLWhitespace(text, attributeValue)))) {
          return YES;
        }
        NSRange valueRange = NSMakeRange(NSNotFound, 0);
        NSUInteger nextIndex = tag.nextIndex;
        if (!DSHParseSimpleXMLElement(text, tag, &valueRange, &nextIndex) ||
            !DSHCredentialValueRangeIsApproved(text, valueRange)) {
          return YES;
        }
        index = nextIndex;
        continue;
      }
      if (!tag.closing &&
          DSHRangeEqualsASCII(text, tag.localName, "property")) {
        NSRange keyRange = NSMakeRange(NSNotFound, 0);
        DSHXMLAttributeResult keyResult =
            DSHFindXMLAttribute(text, tag, "name", &keyRange);
        if (keyResult == DSHXMLAttributeMalformed) {
          return YES;
        }
        if (keyResult == DSHXMLAttributeFound &&
            DSHCanonicalCredentialKeyMatches(text, keyRange, NO, YES)) {
          NSRange valueRange = NSMakeRange(NSNotFound, 0);
          DSHXMLAttributeResult valueResult =
              DSHFindXMLAttribute(text, tag, "value", &valueRange);
          if (valueResult != DSHXMLAttributeFound ||
              !DSHCredentialValueRangeIsApproved(
                  text,
                  DSHRangeByTrimmingXMLWhitespace(text, valueRange))) {
            return YES;
          }
          index = tag.nextIndex;
          continue;
        }
      }
      if (!tag.closing && DSHRangeEqualsASCII(text, tag.localName, "key")) {
        NSRange keyRange = NSMakeRange(NSNotFound, 0);
        NSUInteger afterKey = tag.nextIndex;
        if (DSHParseSimpleXMLElement(text, tag, &keyRange, &afterKey)) {
          keyRange = DSHRangeByTrimmingXMLWhitespace(text, keyRange);
          if (DSHCanonicalCredentialKeyMatches(text, keyRange, NO, YES)) {
            NSUInteger stringStart = DSHSkipXMLWhitespace(text, afterKey);
            DSHXMLTag stringTag = DSHParseXMLTag(text, stringStart);
            NSRange valueRange = NSMakeRange(NSNotFound, 0);
            NSUInteger afterString = stringTag.nextIndex;
            if (!stringTag.valid || stringTag.closing ||
                !DSHRangeEqualsASCII(text, stringTag.localName, "string") ||
                !DSHParseSimpleXMLElement(text, stringTag, &valueRange,
                                          &afterString) ||
                !DSHCredentialValueRangeIsApproved(text, valueRange)) {
              return YES;
            }
            index = afterString;
            continue;
          }
          index = afterKey;
          continue;
        }
      }
      index = MAX(index + 1, tag.nextIndex);
      continue;
    }
    if (character == '[') {
      NSUInteger nextIndex = index + 1;
      if (DSHBracketExpressionIsUnsafe(text, index, &nextIndex)) {
        return YES;
      }
      index = MAX(index + 1, nextIndex);
      continue;
    }
    if (character == '\"' || character == '\'' || character == '`') {
      DSHQuotedToken token = DSHParseQuotedToken(text, index);
      if (DSHQuotedJSONCredentialKeyIsUnsafe(text, index, token)) {
        return YES;
      }
      index = MAX(index + 1, token.nextIndex);
      continue;
    }
    index++;
  }
  return NO;
}

static double DSHShannonEntropy(NSString *value) {
  NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
  if (data.length == 0) {
    return 0.0;
  }
  NSUInteger counts[256] = {0};
  const uint8_t *bytes = (const uint8_t *)data.bytes;
  for (NSUInteger index = 0; index < data.length; index++) {
    counts[bytes[index]]++;
  }
  double entropy = 0.0;
  for (NSUInteger index = 0; index < 256; index++) {
    if (counts[index] == 0) {
      continue;
    }
    double probability = (double)counts[index] / (double)data.length;
    entropy -= probability * log2(probability);
  }
  return entropy;
}

static BOOL DSHHasHighEntropyCredentialLikeValue(NSString *text) {
  static NSRegularExpression *expression;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    expression = DSHCompileExpression(@"[A-Za-z0-9+/_=-]{32,512}", 0);
  });
  NSArray<NSTextCheckingResult *> *matches =
      [expression matchesInString:text options:0 range:NSMakeRange(0, text.length)];
  for (NSTextCheckingResult *match in matches) {
    NSString *value = [text substringWithRange:match.range];
    BOOL lower = NO;
    BOOL upper = NO;
    BOOL digit = NO;
    BOOL symbol = NO;
    NSData *bytes = [value dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *characters = (const uint8_t *)bytes.bytes;
    for (NSUInteger index = 0; index < bytes.length; index++) {
      lower |= islower(characters[index]) != 0;
      upper |= isupper(characters[index]) != 0;
      digit |= isdigit(characters[index]) != 0;
      symbol |= !isalnum(characters[index]);
    }
    NSUInteger categories = (lower ? 1 : 0) + (upper ? 1 : 0) +
                            (digit ? 1 : 0) + (symbol ? 1 : 0);
    if (categories >= 3 && DSHShannonEntropy(value) >= 4.0) {
      return YES;
    }
  }
  return NO;
}

static NSSet<NSString *> *DSHCandidateKeys(void) {
  static NSSet<NSString *> *values;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    values = [NSSet setWithArray:@[
      @"path", @"size", @"revision", @"git_state", @"eligible",
      @"omission_reason"
    ]];
  });
  return values;
}

static NSSet<NSString *> *DSHCandidateGitStates(void) {
  static NSSet<NSString *> *values;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    values = [NSSet setWithArray:@[
      @"unchanged", @"staged", @"unstaged", @"conflicted"
    ]];
  });
  return values;
}

static NSSet<NSString *> *DSHCandidateOmissionReasons(void) {
  static NSSet<NSString *> *values;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    values = [NSSet setWithArray:@[
      DSHProjectContextOmissionReasonSecretPath,
      DSHProjectContextOmissionReasonGenerated,
      DSHProjectContextOmissionReasonLockfile,
      DSHProjectContextOmissionReasonSuspectedSecret,
      DSHProjectContextOmissionReasonBinary,
      DSHProjectContextOmissionReasonInvalidEncoding,
      DSHProjectContextOmissionReasonNotTracked,
      DSHProjectContextOmissionReasonBudgetExceeded,
      DSHProjectContextOmissionReasonPolicy,
    ]];
  });
  return values;
}

static BOOL DSHIsActualBoolean(id value) {
  return value == (__bridge id)kCFBooleanTrue ||
         value == (__bridge id)kCFBooleanFalse;
}

static BOOL DSHSnapshotNonnegativeSafeIntegerNumber(
    id value,
    unsigned long long *canonicalValue) {
  if (![value isKindOfClass:NSNumber.class] || DSHIsActualBoolean(value)) {
    return NO;
  }
  double number = [(NSNumber *)value doubleValue];
  if (!isfinite(number) || number < 0.0 || floor(number) != number ||
      number > 9007199254740991.0) {
    return NO;
  }
  if (canonicalValue != nullptr) {
    *canonicalValue = (unsigned long long)number;
  }
  return YES;
}

static BOOL DSHIsNonemptyBoundedUTF8String(id value, NSUInteger maxBytes) {
  if (![value isKindOfClass:NSString.class]) {
    return NO;
  }
  NSString *string = value;
  if (string.length == 0 || string.length > maxBytes ||
      ![string canBeConvertedToEncoding:NSUTF8StringEncoding]) {
    return NO;
  }
  return [string lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= maxBytes;
}

static NSDictionary<NSString *, id> *DSHCanonicalCandidateIfValid(
    NSDictionary<NSString *, id> *candidate) {
  NSMutableSet<NSString *> *seenKeys =
      [NSMutableSet setWithCapacity:DSHCandidateKeys().count];
  NSUInteger enumeratedKeyCount = 0;
  for (id key in candidate) {
    enumeratedKeyCount++;
    if (enumeratedKeyCount > DSHCandidateKeys().count) {
      return nil;
    }
    if (![key isKindOfClass:NSString.class] || [key length] == 0 ||
        [key length] > DSHCandidateKeyMaxCharacters) {
      return nil;
    }
    NSString *canonicalKey = [(NSString *)key copy];
    if (![DSHCandidateKeys() containsObject:canonicalKey] ||
        [seenKeys containsObject:canonicalKey]) {
      return nil;
    }
    [seenKeys addObject:canonicalKey];
  }
  if (enumeratedKeyCount != DSHCandidateKeys().count ||
      ![seenKeys isEqualToSet:DSHCandidateKeys()]) {
    return nil;
  }

  id rawPath = candidate[@"path"];
  id rawSize = candidate[@"size"];
  id rawRevision = candidate[@"revision"];
  id rawGitState = candidate[@"git_state"];
  id rawEligible = candidate[@"eligible"];
  id rawOmissionReason = candidate[@"omission_reason"];
  if (![rawPath isKindOfClass:NSString.class] || [rawPath length] == 0 ||
      [rawPath length] > DSHCandidatePathMaxBytes ||
      ![rawRevision isKindOfClass:NSString.class] ||
      [rawRevision length] == 0 ||
      [rawRevision length] > DSHCandidateRevisionMaxBytes ||
      ![rawGitState isKindOfClass:NSString.class] ||
      [rawGitState length] == 0 ||
      [rawGitState length] > DSHCandidateGitStateMaxCharacters ||
      !DSHIsActualBoolean(rawEligible)) {
    return nil;
  }

  unsigned long long canonicalSize = 0;
  if (!DSHSnapshotNonnegativeSafeIntegerNumber(rawSize, &canonicalSize)) {
    return nil;
  }
  NSString *pathInput = [(NSString *)rawPath copy];
  NSString *revision = [(NSString *)rawRevision copy];
  NSString *gitState = [(NSString *)rawGitState copy];
  if (!DSHIsNonemptyBoundedUTF8String(pathInput, DSHCandidatePathMaxBytes) ||
      !DSHIsNonemptyBoundedUTF8String(revision,
                                      DSHCandidateRevisionMaxBytes) ||
      ![DSHCandidateGitStates() containsObject:gitState]) {
    return nil;
  }
  NSString *path = [DSHNFCString(pathInput) copy];
  if (!DSHRelativePathHasSafeStructure(path)) {
    return nil;
  }

  BOOL isEligible = rawEligible == (__bridge id)kCFBooleanTrue;
  id omissionReason = NSNull.null;
  if (isEligible) {
    if (rawOmissionReason != NSNull.null) {
      return nil;
    }
  } else {
    if (![rawOmissionReason isKindOfClass:NSString.class] ||
        [rawOmissionReason length] == 0 ||
        [rawOmissionReason length] >
            DSHCandidateOmissionReasonMaxCharacters) {
      return nil;
    }
    omissionReason = [(NSString *)rawOmissionReason copy];
    if (![DSHCandidateOmissionReasons() containsObject:omissionReason]) {
      return nil;
    }
  }

  return @{
    @"path" : path,
    @"size" : @(canonicalSize),
    @"revision" : revision,
    @"git_state" : gitState,
    @"eligible" : @(isEligible),
    @"omission_reason" : omissionReason,
  };
}

static NSDictionary<NSString *, id> *DSHMetadataOnlyCandidate(
    NSDictionary<NSString *, id> *candidate) {
  id omissionReason = candidate[@"omission_reason"];
  return @{
    @"path" : [candidate[@"path"] copy],
    @"size" : @([candidate[@"size"] unsignedLongLongValue]),
    @"revision" : [candidate[@"revision"] copy],
    @"git_state" : [candidate[@"git_state"] copy],
    @"eligible" : @([candidate[@"eligible"] boolValue]),
    @"omission_reason" : omissionReason == NSNull.null
        ? NSNull.null
        : [omissionReason copy],
  };
}

static NSComparisonResult DSHCompareCandidates(NSDictionary<NSString *, id> *left,
                                                NSDictionary<NSString *, id> *right) {
  NSString *leftPath = left[@"path"];
  NSString *rightPath = right[@"path"];
  NSComparisonResult result = [leftPath compare:rightPath options:NSLiteralSearch];
  if (result != NSOrderedSame) {
    return result;
  }
  result = [left[@"revision"] compare:right[@"revision"] options:NSLiteralSearch];
  if (result != NSOrderedSame) {
    return result;
  }
  result = [left[@"git_state"] compare:right[@"git_state"] options:NSLiteralSearch];
  if (result != NSOrderedSame) {
    return result;
  }
  result = [left[@"size"] compare:right[@"size"]];
  if (result != NSOrderedSame) {
    return result;
  }
  result = [left[@"eligible"] compare:right[@"eligible"]];
  if (result != NSOrderedSame) {
    return result;
  }
  return [[left[@"omission_reason"] description]
      compare:[right[@"omission_reason"] description]
      options:NSLiteralSearch];
}

@implementation DSHProjectContextPolicy

- (instancetype)init {
  self = [super init];
  if (self) {
    NSMutableData *key = [NSMutableData dataWithLength:CC_SHA256_DIGEST_LENGTH];
    if (SecRandomCopyBytes(kSecRandomDefault, key.length, key.mutableBytes) !=
        errSecSuccess) {
      arc4random_buf(key.mutableBytes, key.length);
    }
    _cursorKey = [key copy];
  }
  return self;
}

- (DSHProjectContextPathDecision *)decisionForRelativePath:(NSString *)relativePath {
  // The bound is decided on the reported length alone, before a single
  // character is read: normalizing first would do work proportional to a
  // hostile input that is about to be refused anyway. The core bounds it too,
  // but by then the copy has already happened, so this check stays here.
  if (![relativePath isKindOfClass:NSString.class] || relativePath.length == 0 ||
      relativePath.length > DSHProjectContextMaxRelativePathCharacters) {
    return [[DSHProjectContextPathDecision alloc]
        initWithNormalizedPath:@""
                     eligible:NO
                omissionReason:DSHProjectContextOmissionReasonPolicy];
  }
  NSString *normalized = DSHNFCString(relativePath);
  NSMutableArray *components = [NSMutableArray array];
  for (NSString *component in [normalized componentsSeparatedByString:@"/"]) {
    [components addObject:DSHFoldedComponent(component)];
  }
  NSString *filename = [normalized componentsSeparatedByString:@"/"].lastObject ?: @"";
  NSDictionary *reply = DSHPolicyReduce(@"path_decision", @{
    @"path" : relativePath,
    @"normalized" : normalized,
    @"components" : components,
    @"filename" : DSHFoldedComponent(filename),
    // The extension is folded *after* Foundation takes it, which is how this
    // policy has always spelled it.
    @"filename_extension" : DSHFoldedString(filename.pathExtension ?: @""),
  });
  if (reply == nil) {
    return [[DSHProjectContextPathDecision alloc]
        initWithNormalizedPath:normalized
                     eligible:NO
                omissionReason:DSHProjectContextOmissionReasonPolicy];
  }
  id reason = reply[@"omission_reason"];
  return [[DSHProjectContextPathDecision alloc]
      initWithNormalizedPath:reply[@"normalized_path"] ?: normalized
                   eligible:[reply[@"eligible"] isEqual:@YES]
              omissionReason:[reason isKindOfClass:NSString.class] ? reason : nil];
}

- (DSHProjectContextContentDecision *)decisionForContentData:(NSData *)data {
  if (data.length > DSHProjectContextMaxFileBytes) {
    return [[DSHProjectContextContentDecision alloc]
        initWithEligible:NO
           omissionReason:DSHProjectContextOmissionReasonBudgetExceeded];
  }
  const uint8_t *bytes = (const uint8_t *)data.bytes;
  for (NSUInteger index = 0; index < data.length; index++) {
    if (bytes[index] == 0) {
      return [[DSHProjectContextContentDecision alloc]
          initWithEligible:NO
             omissionReason:DSHProjectContextOmissionReasonBinary];
    }
  }
  NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if (text == nil) {
    return [[DSHProjectContextContentDecision alloc]
        initWithEligible:NO
           omissionReason:DSHProjectContextOmissionReasonInvalidEncoding];
  }
  NSCharacterSet *controls = NSCharacterSet.controlCharacterSet;
  for (NSUInteger index = 0; index < text.length; index++) {
    unichar character = [text characterAtIndex:index];
    if ([controls characterIsMember:character] && character != '\t' &&
        character != '\n' && character != '\r' && character != '\f') {
      return [[DSHProjectContextContentDecision alloc]
          initWithEligible:NO
             omissionReason:DSHProjectContextOmissionReasonBinary];
    }
  }
  return [[DSHProjectContextContentDecision alloc] initWithEligible:YES
                                                     omissionReason:nil];
}

- (DSHProjectContextSecretDecision *)secretDecisionForData:(NSData *)data {
  NSUInteger length = MIN(data.length, DSHProjectContextMaxFileBytes);
  NSData *bounded = [data subdataWithRange:NSMakeRange(0, length)];
  NSString *text = [[NSString alloc] initWithData:bounded encoding:NSUTF8StringEncoding];
  if (text == nil && data.length > length) {
    NSUInteger maximumTrim = MIN((NSUInteger)3, bounded.length);
    for (NSUInteger trim = 1; trim <= maximumTrim && text == nil; trim++) {
      NSData *prefix = [bounded subdataWithRange:NSMakeRange(0, bounded.length - trim)];
      text = [[NSString alloc] initWithData:prefix encoding:NSUTF8StringEncoding];
    }
  }
  if (text == nil) {
    return [[DSHProjectContextSecretDecision alloc]
        initWithSuspectedSecret:NO
                 omissionReason:nil];
  }

  BOOL suspected =
      DSHStringHasMatch(text, DSHPrivateKeyExpression()) ||
      DSHStringHasMatch(text, DSHKnownTokenExpression()) ||
      DSHStringHasMatch(text, DSHJWTExpression()) ||
      DSHHasUnsafeStructuredCredential(text) ||
      DSHHasCredentialAssignment(text) ||
      DSHHasHighEntropyCredentialLikeValue(text);
  return [[DSHProjectContextSecretDecision alloc]
      initWithSuspectedSecret:suspected
               omissionReason:(suspected
                                   ? DSHProjectContextOmissionReasonSuspectedSecret
                                   : nil)];
}

- (nullable NSString *)encodeCursorForSourceFingerprint:(NSString *)sourceFingerprint
                                                  offset:(NSUInteger)offset
                                                   error:(NSError **)error {
  return [self encodeCursorForSourceFingerprint:sourceFingerprint
                                         offset:offset
                            authenticationScope:NSData.data
                                          error:error];
}

- (nullable NSString *)encodeCursorForSourceFingerprint:(NSString *)sourceFingerprint
                                                  offset:(NSUInteger)offset
                                     authenticationScope:(NSData *)authenticationScope
                                                   error:(NSError **)error {
  if (error != nil) {
    *error = nil;
  }
  if (![sourceFingerprint isKindOfClass:NSString.class] ||
      sourceFingerprint.length == 0 ||
      sourceFingerprint.length >
          DSHProjectContextMaxSourceFingerprintCharacters) {
    DSHSetPolicyError(error, DSHProjectContextPolicyErrorInvalidArgument);
    return nil;
  }
  NSData *fingerprintData =
      [sourceFingerprint dataUsingEncoding:NSUTF8StringEncoding];
  if (fingerprintData.length == 0 || self.cursorKey.length == 0) {
    DSHSetPolicyError(error, DSHProjectContextPolicyErrorInvalidArgument);
    return nil;
  }

  NSMutableData *cursorData = [NSMutableData dataWithLength:DSHCursorBytes];
  uint8_t *bytes = (uint8_t *)cursorData.mutableBytes;
  bytes[0] = DSHCursorVersion;
  uint64_t encodedOffset = (uint64_t)offset;
  for (NSUInteger index = 0; index < sizeof(encodedOffset); index++) {
    bytes[1 + index] =
        (uint8_t)(encodedOffset >> (8 * (sizeof(encodedOffset) - index - 1)));
  }
  NSData *fingerprintDigest = DSHSHA256(fingerprintData);
  memcpy(bytes + 1 + sizeof(encodedOffset), fingerprintDigest.bytes,
         CC_SHA256_DIGEST_LENGTH);
  NSData *payload = [cursorData subdataWithRange:NSMakeRange(0, DSHCursorPayloadBytes)];
  NSData *tag = DSHHMACSHA256(
      self.cursorKey,
      DSHCursorAuthenticationData(payload, authenticationScope));
  memcpy(bytes + DSHCursorPayloadBytes, tag.bytes, CC_SHA256_DIGEST_LENGTH);
  return DSHBase64URLEncode(cursorData);
}

- (BOOL)decodeCursor:(NSString *)cursor
    sourceFingerprint:(NSString *)sourceFingerprint
               offset:(NSUInteger *)offset
                error:(NSError **)error {
  return [self decodeCursor:cursor
          sourceFingerprint:sourceFingerprint
        authenticationScope:NSData.data
                     offset:offset
                      error:error];
}

- (BOOL)decodeCursor:(NSString *)cursor
    sourceFingerprint:(NSString *)sourceFingerprint
  authenticationScope:(NSData *)authenticationScope
               offset:(NSUInteger *)offset
                error:(NSError **)error {
  if (error != nil) {
    *error = nil;
  }
  if (![cursor isKindOfClass:NSString.class]) {
    DSHSetPolicyError(error, DSHProjectContextPolicyErrorInvalidCursor);
    return NO;
  }
  NSData *cursorData = DSHBase64URLDecode(cursor);
  if (cursorData.length != DSHCursorBytes || self.cursorKey.length == 0) {
    DSHSetPolicyError(error, DSHProjectContextPolicyErrorInvalidCursor);
    return NO;
  }
  if (![sourceFingerprint isKindOfClass:NSString.class] ||
      sourceFingerprint.length == 0 ||
      sourceFingerprint.length >
          DSHProjectContextMaxSourceFingerprintCharacters) {
    DSHSetPolicyError(error, DSHProjectContextPolicyErrorInvalidCursor);
    return NO;
  }
  NSData *fingerprintData =
      [sourceFingerprint dataUsingEncoding:NSUTF8StringEncoding];
  if (fingerprintData.length == 0) {
    DSHSetPolicyError(error, DSHProjectContextPolicyErrorInvalidCursor);
    return NO;
  }

  const uint8_t *bytes = (const uint8_t *)cursorData.bytes;
  NSData *payload = [cursorData subdataWithRange:NSMakeRange(0, DSHCursorPayloadBytes)];
  NSData *expectedTag = DSHHMACSHA256(
      self.cursorKey,
      DSHCursorAuthenticationData(payload, authenticationScope));
  if (!DSHConstantTimeEqual(bytes + DSHCursorPayloadBytes,
                            (const uint8_t *)expectedTag.bytes,
                            CC_SHA256_DIGEST_LENGTH) ||
      bytes[0] != DSHCursorVersion) {
    DSHSetPolicyError(error, DSHProjectContextPolicyErrorInvalidCursor);
    return NO;
  }

  NSData *fingerprintDigest = DSHSHA256(fingerprintData);
  if (!DSHConstantTimeEqual(bytes + 1 + sizeof(uint64_t),
                            (const uint8_t *)fingerprintDigest.bytes,
                            CC_SHA256_DIGEST_LENGTH)) {
    DSHSetPolicyError(error, DSHProjectContextPolicyErrorStaleCursor);
    return NO;
  }

  uint64_t decodedOffset = 0;
  for (NSUInteger index = 0; index < sizeof(decodedOffset); index++) {
    decodedOffset = (decodedOffset << 8) | bytes[1 + index];
  }
  if (decodedOffset > NSUIntegerMax) {
    DSHSetPolicyError(error, DSHProjectContextPolicyErrorInvalidCursor);
    return NO;
  }
  if (offset != nil) {
    *offset = (NSUInteger)decodedOffset;
  }
  return YES;
}

- (nullable NSDictionary<NSString *, id> *)
    candidatePageForCandidates:(NSArray<NSDictionary<NSString *, id> *> *)candidates
                          query:(NSString *)query
              sourceFingerprint:(NSString *)sourceFingerprint
                         cursor:(nullable NSString *)cursor
                          limit:(NSUInteger)limit
                          error:(NSError **)error {
  if (error != nil) {
    *error = nil;
  }
  if (limit == 0 || ![candidates isKindOfClass:NSArray.class] ||
      ![query isKindOfClass:NSString.class] ||
      query.length > DSHProjectContextMaxQueryCharacters ||
      ![query canBeConvertedToEncoding:NSUTF8StringEncoding] ||
      ![sourceFingerprint isKindOfClass:NSString.class] ||
      sourceFingerprint.length == 0 ||
      sourceFingerprint.length >
          DSHProjectContextMaxSourceFingerprintCharacters ||
      ![sourceFingerprint canBeConvertedToEncoding:NSUTF8StringEncoding]) {
    DSHSetPolicyError(error, DSHProjectContextPolicyErrorInvalidArgument);
    return nil;
  }
  NSMutableArray<NSDictionary<NSString *, id> *> *candidateSnapshot =
      [NSMutableArray array];
  NSUInteger enumeratedCandidateCount = 0;
  for (id candidate in candidates) {
    enumeratedCandidateCount++;
    if (enumeratedCandidateCount > DSHProjectContextMaxEntries) {
      DSHSetPolicyError(error, DSHProjectContextPolicyErrorBudgetExceeded);
      return nil;
    }
    [candidateSnapshot addObject:candidate];
  }

  NSString *normalizedQuery = DSHFoldedString(query);
  NSData *queryScope = DSHSHA256(
      [normalizedQuery dataUsingEncoding:NSUTF8StringEncoding]);
  NSMutableArray<NSDictionary<NSString *, id> *> *filtered =
      [NSMutableArray array];
  for (NSDictionary<NSString *, id> *candidate in candidateSnapshot) {
    if (![candidate isKindOfClass:NSDictionary.class]) {
      DSHSetPolicyError(error, DSHProjectContextPolicyErrorInvalidArgument);
      return nil;
    }
    NSDictionary<NSString *, id> *canonicalCandidate =
        DSHCanonicalCandidateIfValid(candidate);
    if (canonicalCandidate == nil) {
      DSHSetPolicyError(error, DSHProjectContextPolicyErrorInvalidArgument);
      return nil;
    }
    DSHProjectContextPathDecision *pathDecision =
        [self decisionForRelativePath:canonicalCandidate[@"path"]];
    if (!pathDecision.eligible &&
        ([canonicalCandidate[@"eligible"] boolValue] ||
         ![canonicalCandidate[@"omission_reason"]
             isEqual:pathDecision.omissionReason])) {
      DSHSetPolicyError(error, DSHProjectContextPolicyErrorInvalidArgument);
      return nil;
    }
    unsigned long long fileSize =
        [canonicalCandidate[@"size"] unsignedLongLongValue];
    if (pathDecision.eligible &&
        fileSize > DSHProjectContextMaxFileBytes &&
        ([canonicalCandidate[@"eligible"] boolValue] ||
         ![canonicalCandidate[@"omission_reason"]
             isEqual:DSHProjectContextOmissionReasonBudgetExceeded])) {
      DSHSetPolicyError(error, DSHProjectContextPolicyErrorInvalidArgument);
      return nil;
    }
    NSString *normalizedPath = DSHFoldedString(canonicalCandidate[@"path"]);
    if (normalizedQuery.length == 0 ||
        [normalizedPath rangeOfString:normalizedQuery options:NSLiteralSearch].location !=
            NSNotFound) {
      [filtered addObject:canonicalCandidate];
    }
  }
  [filtered sortUsingComparator:^NSComparisonResult(
                NSDictionary<NSString *, id> *left,
                NSDictionary<NSString *, id> *right) {
    return DSHCompareCandidates(left, right);
  }];

  NSUInteger offset = 0;
  if (cursor != nil &&
      ![self decodeCursor:cursor
        sourceFingerprint:sourceFingerprint
      authenticationScope:queryScope
                   offset:&offset
                    error:error]) {
    return nil;
  }
  if (offset > filtered.count) {
    DSHSetPolicyError(error, DSHProjectContextPolicyErrorInvalidCursor);
    return nil;
  }

  NSUInteger pageSize = MIN(limit, DSHProjectContextMaxCandidatePageSize);
  NSUInteger end = MIN(filtered.count, offset + pageSize);
  NSMutableArray<NSDictionary<NSString *, id> *> *page =
      [NSMutableArray arrayWithCapacity:end - offset];
  for (NSUInteger index = offset; index < end; index++) {
    [page addObject:DSHMetadataOnlyCandidate(filtered[index])];
  }

  id nextCursor = NSNull.null;
  if (end < filtered.count) {
    NSString *encoded = [self encodeCursorForSourceFingerprint:sourceFingerprint
                                                        offset:end
                                           authenticationScope:queryScope
                                                         error:error];
    if (encoded == nil) {
      return nil;
    }
    nextCursor = encoded;
  }
  return @{
    @"candidates" : [page copy],
    @"next_cursor" : nextCursor,
  };
}

@end
