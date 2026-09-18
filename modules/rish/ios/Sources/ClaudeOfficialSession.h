#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Phone-local login for an UNMODIFIED Claude Code CLI inside a reusable guest
/// VM. The actor owns a persistent guest HOME disk image (app-container,
/// file-protected) so Claude subscription credentials never leave the guest
/// disk: this class never copies tokens, auth JSON, process output, or the
/// user's login code into any host HTTP adapter, Keychain item, or bridge
/// payload. Only the bounded public status envelope below is exposed.
///
/// All work runs on the actor's serial queue (FFI exchanges are serialized
/// through it, so guest control calls never overlap); UI completions always
/// return on the main queue.
@interface DSHClaudeOfficialSession : NSObject

/// Kernel/initrd URLs and disk storage directory are supplied pre-verified by
/// the root integrator. A nil URL or empty version yields a runtime that
/// reports itself unavailable rather than attempting a boot.
- (instancetype)initWithKernelURL:(nullable NSURL *)kernelURL
                        initrdURL:(nullable NSURL *)initrdURL
                  storageDirectory:(nullable NSURL *)storageDirectory
                          version:(NSString *)version;

/// Synchronized cached status snapshot with the HarnessAuthService contract:
/// schema_version 1, harness_id "claude-code", runtime{kind:"official-cli",
/// available, version}, status unavailable|signed_out|authorizing|signed_in|
/// error, auth_method none|subscription, and while authorizing a login dict
/// {session_id, phase starting|waiting_for_browser|verifying, verification_url
/// (optional), can_submit_code, expires_at (epoch seconds)}.
@property (nonatomic, readonly, copy) NSDictionary *status;
/// The host-downloaded CLI binary, delivered to the guest as a data disk and
/// installed into the persistent home disk on first boot. Set before use.
@property (nonatomic, copy, nullable) NSURL *cliDeliveryURL;
/// Scheduling hint only. Never grants signed-in status without CLI verification.
@property (nonatomic, readonly) BOOL shouldRestoreSavedSession;

- (void)startLogin:(void (^)(NSDictionary *status))completion;
- (void)cancelSession:(NSString *)sessionId
           completion:(void (^)(NSDictionary *status))completion;
- (void)submitCode:(NSString *)code
           session:(NSString *)sessionId
        completion:(void (^)(NSDictionary *status))completion;
- (void)refresh:(void (^)(NSDictionary *status))completion;
- (void)logout:(void (^)(NSDictionary *status))completion;

#pragma mark Official CLI text completion

/// Runs one bounded, text-only request through the unmodified official CLI.
/// The request contains request_id, model, prompt, and optional thinking_mode (default off). Prompt bytes are sent
/// over guest stdin and are never included in argv or diagnostics. Completion
/// receives either the normalized fragment or a stable private error code.
- (void)completeTextRequest:(NSDictionary *)request
                 completion:(void (^)(NSDictionary * _Nullable result,
                                      NSString * _Nullable errorCode))completion;
/// Cancels the request owned by requestId. Cancellation is generation based,
/// so a late worker cannot publish a result for a newer request.
- (void)cancelTextRequest:(NSString *)requestId;

#pragma mark Pure seams (no VM, no network, no disk)

/// Normalizes one guest control exchange (outer {protocol_version, ok,
/// exchange:{response, events}} envelope, tagged guest-protocol payloads
/// inside) into {ok, request_id, execution_id, pong, streams (decoded NSData,
/// bounded), exited (NSNumber when ProcessExited was seen), error}. Returns an
/// empty dictionary for anything malformed.
+ (NSDictionary *)parseControlExchange:(nullable NSDictionary *)exchange;

/// Parses `claude auth status --json` output into {logged_in, subscription,
/// auth_method}. subscription is true only when loggedIn is true AND the auth
/// method is the claude.ai subscription method.
+ (NSDictionary *)authStatusFromGuestJSON:(nullable NSDictionary *)json;

/// Accepts only 1...2048 printable single-line ASCII characters (0x20-0x7e);
/// anything else returns nil so no control characters or shell syntax can
/// reach the guest stdin stream.
+ (nullable NSString *)validatedLoginCode:(NSString *)code;

/// Parses one official `claude -p --output-format json` stdout object into the
/// public text fragment. Stderr and unknown private fields are discarded.
+ (nullable NSDictionary *)normalizedTextResultFromJSON:(nullable id)json
                                                   model:(NSString *)model;
/// Exact argv suffix used by text completion (the binary path is prepended by
/// the guest command helper). Exposed so transport audit/digest code cannot
/// drift from the worker's official CLI contract.
+ (NSArray<NSString *> *)textArgumentsForModel:(NSString *)model;
/// off/low/medium/high; unknown modes return an empty argument list.
+ (NSArray<NSString *> *)textArgumentsForModel:(NSString *)model thinkingMode:(NSString *)thinkingMode;

#pragma mark Injected-exchange test seams (never used in production paths)

/// When set, replaces every guest control FFI exchange: receives the full
/// protocol request envelope and returns the raw exchange reply dictionary.
@property (nonatomic, copy, nullable)
    NSDictionary *(^controlExchangeOverride)(NSDictionary *request);

/// When set, replaces rish_vm_boot_session; @YES means a guest handle exists.
@property (nonatomic, copy, nullable) BOOL (^guestBootOverride)(NSDictionary *request);

@end

NS_ASSUME_NONNULL_END
