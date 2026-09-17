#import "ClaudeOfficialSession.h"

#import "HarnessAuthService.h"
#import "DSHGuestRuntimeState.h"
#import "rish.h"
#include <sys/stat.h>

// Weak like the existing stream import, so this module stays loadable and
// reports unavailable when linked against a runtime that predates it.
extern "C" char *rish_vm_session_control_json(void *session,
                                              const char *input,
                                              size_t input_len)
    __attribute__((weak_import));

static NSString *const DSHClaudeHarnessId = @"claude-code";
static NSString *const DSHClaudeGuestBinary = @"/opt/harness/claude";
static NSString *const DSHClaudeGuestMountPoint = @"/mnt/claude";
static NSString *const DSHClaudeGuestHome = @"/mnt/claude/home";
static NSString *const DSHClaudeGuestConfig = @"/mnt/claude/home/.claude";
static NSString *const DSHClaudeDiskImageName = @"guest-home.img";
static NSUInteger const DSHClaudeDiskBytes = 64 * 1024 * 1024;
static NSUInteger const DSHClaudeMaxOutputBytes = 64 * 1024;
static NSUInteger const DSHClaudeMaxReplyBytes = 1024 * 1024;
static NSTimeInterval const DSHClaudeLoginTimeout = 600.0;
static NSTimeInterval const DSHClaudeBrowserTimeout = 1800.0;
static NSTimeInterval const DSHClaudePollInterval = 0.25;
static NSTimeInterval const DSHClaudeCancelPumpTimeout = 10.0;
static NSUInteger const DSHClaudeMaxCodeLength = 2048;
static NSUInteger const DSHClaudeMaxPromptBytes = 64 * 1024;
// Wall-clock bound for one text completion. The transport's outer limit is
// 900s; stay inside it so the native timer, not the transport, reports first.
static NSTimeInterval const DSHClaudeTextTimeout = 840.0;

static NSString *const DSHClaudeErrorSessionInvalid =
    @"E_CLAUDE_OFFICIAL_SESSION_INVALID";
static NSString *const DSHClaudeErrorSessionNotFound =
    @"E_CLAUDE_OFFICIAL_SESSION_NOT_FOUND";
static NSString *const DSHClaudeErrorCodeInvalid =
    @"E_CLAUDE_OFFICIAL_CODE_INVALID";
static NSString *const DSHClaudeErrorGuestBoot =
    @"E_CLAUDE_OFFICIAL_GUEST_BOOT_FAILED";
static NSString *const DSHClaudeErrorDiskFormat =
    @"E_CLAUDE_OFFICIAL_DISK_FORMAT_FAILED";
static NSString *const DSHClaudeErrorDiskMount =
    @"E_CLAUDE_OFFICIAL_DISK_MOUNT_FAILED";
static NSString *const DSHClaudeErrorLoginFailed =
    @"E_CLAUDE_OFFICIAL_LOGIN_FAILED";
static NSString *const DSHClaudeErrorLoginTimeout =
    @"E_CLAUDE_OFFICIAL_LOGIN_TIMEOUT";
static NSString *const DSHClaudeErrorLogoutFailed =
    @"E_CLAUDE_OFFICIAL_LOGOUT_FAILED";
static NSString *const DSHClaudeErrorTextInvalid =
    @"E_CLAUDE_OFFICIAL_TEXT_INVALID";
static NSString *const DSHClaudeErrorTextBusy =
    @"E_CLAUDE_OFFICIAL_TEXT_BUSY";
static NSString *const DSHClaudeErrorTextAuthRequired =
    @"E_CLAUDE_OFFICIAL_TEXT_AUTH_REQUIRED";
static NSString *const DSHClaudeErrorTextTimeout =
    @"E_CLAUDE_OFFICIAL_TEXT_TIMEOUT";
static NSString *const DSHClaudeErrorTextCancelled =
    @"E_CLAUDE_OFFICIAL_TEXT_CANCELLED";
static NSString *const DSHClaudeErrorTextFailed =
    @"E_CLAUDE_OFFICIAL_TEXT_FAILED";

static BOOL DSHClaudeControlFFIAvailable(void) {
  return rish_vm_session_control_json != NULL;
}

static BOOL DSHClaudeValidSessionId(id value) {
  return [value isKindOfClass:NSString.class] &&
         [(NSString *)value length] > 0 &&
         [(NSString *)value length] <= 128 &&
         [(NSString *)value rangeOfString:@"\0"].location == NSNotFound;
}

@interface DSHClaudeOfficialSession ()
@property (nonatomic) BOOL cleanupPending;
@property (nonatomic) NSUInteger guestIdleEpoch;
@property (nonatomic) BOOL guestReuseAllowed;
@property (nonatomic) BOOL guestEvictionRequested;
// One CLI startup measurement per process lifetime: separates interpreter
// startup cost from model round-trip time in text diagnostics.
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) dispatch_queue_t workerQueue;
@property (nonatomic, strong) NSURL *kernelURL;
@property (nonatomic, strong) NSURL *initrdURL;
@property (nonatomic, strong) NSURL *storageDirectory;
@property (nonatomic, copy) NSString *version;
// Every guest control exchange is dispatched synchronously through `queue`,
// so FFI calls from worker threads never overlap each other or a session
// free. Everything below is read and written under @synchronized(self).
@property (nonatomic) void *vmHandle;
@property (nonatomic, strong) DSHGuestVMOwner *vmOwner;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) NSUInteger configurationRepairGeneration;
@property (nonatomic, copy) NSString *activeSessionId;
@property (nonatomic, copy) NSString *activePhase;
@property (nonatomic, copy) NSString *activeVerificationURL;
@property (nonatomic) NSTimeInterval loginExpiresAt;
@property (nonatomic, strong) NSMutableData *loginOutput;
@property (nonatomic, copy) NSString *activeExecutionID;
@property (nonatomic, copy) NSString *activeRequestID;
@property (nonatomic) BOOL signedIn;
@property (nonatomic, copy) NSString *lastErrorCode;
@property (nonatomic, copy) NSString *activeTextRequestId;
@property (nonatomic) NSUInteger textGeneration;
@property (nonatomic, strong) NSMutableSet<NSString *> *pendingTextCancels;
- (NSDictionary *)performExchangeForPayload:(NSDictionary *)payload;
- (NSDictionary *)runGuestTextCommand:(NSString *)requestId
                                model:(NSString *)model
                               prompt:(NSString *)prompt
                         thinkingMode:(NSString *)thinkingMode
                           generation:(NSUInteger)generation;
@end

@implementation DSHClaudeOfficialSession

#pragma mark Lifecycle

- (instancetype)initWithKernelURL:(NSURL *)kernelURL
                        initrdURL:(NSURL *)initrdURL
                  storageDirectory:(NSURL *)storageDirectory
                          version:(NSString *)version {
  self = [super init];
  if (self != nil) {
    _kernelURL = kernelURL;
    _initrdURL = initrdURL;
    _storageDirectory = storageDirectory;
    _version = [version copy] ?: @"";
    _queue = dispatch_queue_create("tech.zseven.rish.claude-official",
                                   DISPATCH_QUEUE_SERIAL);
    _workerQueue = dispatch_queue_create(
        "tech.zseven.rish.claude-official-worker",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                QOS_CLASS_USER_INITIATED, 0));
    _loginOutput = [NSMutableData data];
    _pendingTextCancels = [NSMutableSet set];
    _guestReuseAllowed = YES;
    NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
    [notifications addObserver:self selector:@selector(guestDidEnterBackground:) name:@"UIApplicationDidEnterBackgroundNotification" object:nil];
    [notifications addObserver:self selector:@selector(guestWillEnterForeground:) name:@"UIApplicationWillEnterForegroundNotification" object:nil];
    [notifications addObserver:self selector:@selector(guestMemoryWarning:) name:@"UIApplicationDidReceiveMemoryWarningNotification" object:nil];
  }
  return self;
}

- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self];
  @synchronized (self) {
    if (_vmHandle != NULL && !self.guestBootOverride) {
      rish_vm_session_free(_vmHandle);
    }
    _vmHandle = NULL;
    if (_vmOwner) [DSHGuestRuntimeState.sharedState releaseGuestOwner:_vmOwner];
    _vmOwner = nil;
  }
}

// Keep only a healthy, idle VM briefly; every request still owns a fresh CLI.
- (void)retainHealthyGuestIfIdle {
  NSUInteger epoch = 0;
  void *handle = NULL;
  BOOL evict = NO;
  @synchronized (self) {
    evict = !self.guestReuseAllowed || self.guestEvictionRequested;
    if (!evict) {
      if (self.vmHandle == NULL || self.activeSessionId.length || self.activeTextRequestId.length) return;
      epoch = ++self.guestIdleEpoch;
      handle = self.vmHandle;
    }
  }
  if (evict) { [self freeGuest]; return; }
  __weak DSHClaudeOfficialSession *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60LL * NSEC_PER_SEC), self.workerQueue, ^{
    [weakSelf expireIdleGuestForEpoch:epoch handle:handle];
  });
}

- (void)expireIdleGuestForEpoch:(NSUInteger)epoch handle:(void *)handle {
  @synchronized (self) {
    if (self.guestIdleEpoch != epoch || self.vmHandle != handle ||
        self.activeSessionId.length || self.activeTextRequestId.length) return;
    self.guestEvictionRequested = YES;
  }
  [self freeGuest];
}

- (void)requestGuestCacheEviction {
  @synchronized (self) { self.guestIdleEpoch += 1; self.guestEvictionRequested = YES; }
  __weak DSHClaudeOfficialSession *weakSelf = self;
  dispatch_async(self.workerQueue, ^{
    DSHClaudeOfficialSession *strongSelf = weakSelf;
    if (strongSelf == nil) return;
    @synchronized (strongSelf) {
      if (strongSelf.activeSessionId.length || strongSelf.activeTextRequestId.length) return;
    }
    [strongSelf freeGuest];
  });
}

- (void)guestDidEnterBackground:(NSNotification *)notification {
  @synchronized (self) { self.guestReuseAllowed = NO; }
  [self requestGuestCacheEviction];
}
- (void)guestWillEnterForeground:(NSNotification *)notification {
  @synchronized (self) { self.guestReuseAllowed = YES; }
}
- (void)guestMemoryWarning:(NSNotification *)notification { [self requestGuestCacheEviction]; }

#pragma mark Status snapshot

- (void)recordDiagnostic:(NSString *)stage details:(NSDictionary *)details {
  @synchronized (self) {
    NSURL *url = [self.storageDirectory URLByAppendingPathComponent:@"diagnostics.json"];
    NSData *previous = [NSData dataWithContentsOfURL:url];
    id decoded = previous ? [NSJSONSerialization JSONObjectWithData:previous options:0 error:nil] : nil;
    NSMutableArray *entries = [decoded isKindOfClass:NSArray.class] ? [decoded mutableCopy] : [NSMutableArray array];
    [entries addObject:@{ @"time": @(NSDate.date.timeIntervalSince1970), @"stage": stage, @"details": details ?: @{} }];
    while (entries.count > 32) [entries removeObjectAtIndex:0];
    NSData *data = [NSJSONSerialization dataWithJSONObject:entries options:0 error:nil];
    [data writeToURL:url options:NSDataWritingAtomic | NSDataWritingFileProtectionComplete error:nil];
  }
}

- (NSURL *)restoreHintURL {
  return [self.storageDirectory URLByAppendingPathComponent:@"verified-session.hint"];
}

- (BOOL)shouldRestoreSavedSession {
  return [NSFileManager.defaultManager fileExistsAtPath:self.restoreHintURL.path] &&
      [NSFileManager.defaultManager fileExistsAtPath:self.diskImageURL.path];
}

- (void)setRestoreHint:(BOOL)verified {
  // This contains no credential and never authenticates an account. It only
  // avoids booting the CLI on every launch after an unsuccessful login attempt.
  if (verified) {
    [NSData.data writeToURL:self.restoreHintURL
                   options:NSDataWritingAtomic | NSDataWritingFileProtectionComplete
                     error:nil];
  } else {
    [NSFileManager.defaultManager removeItemAtURL:self.restoreHintURL error:nil];
  }
}

- (BOOL)runtimeAvailableWithReason:(NSString **)reason {
  NSString *why = nil;
  BOOL ok = self.kernelURL != nil && self.initrdURL != nil &&
            self.storageDirectory != nil && self.version.length > 0;
  if (!ok) {
    why = @"claude-official-assets-not-packaged";
  } else if (!DSHClaudeControlFFIAvailable() && !self.controlExchangeOverride) {
    ok = NO;
    why = @"guest-control-ffi-not-linked";
  }
  if (reason != NULL) *reason = why;
  return ok;
}

- (NSDictionary *)statusSnapshotLocked {
  NSString *reason = nil;
  BOOL available = [self runtimeAvailableWithReason:&reason];
  NSMutableDictionary *runtime = [@{
    @"kind": @"official-cli",
    @"available": @(available),
  } mutableCopy];
  if (self.version.length > 0) runtime[@"version"] = self.version;
  if (reason.length > 0) runtime[@"reason"] = reason;
  NSMutableDictionary *status = [@{
    @"schema_version": @1,
    @"harness_id": DSHClaudeHarnessId,
    @"runtime": runtime,
    @"status": @"unavailable",
    @"auth_method": @"none",
  } mutableCopy];
  if (!available) return status;
  if (self.cleanupPending) {
    runtime[@"available"] = @NO;
    runtime[@"reason"] = @"waiting_for_cleanup";
    if (self.lastErrorCode) status[@"error_code"] = self.lastErrorCode;
    return status;
  }
  if (DSHClaudeValidSessionId(self.activeSessionId)) {
    BOOL canSubmit = self.activeExecutionID.length > 0 &&
        [self.activePhase isEqualToString:@"waiting_for_browser"];
    NSMutableDictionary *login = [@{
      @"session_id": self.activeSessionId,
      @"phase": self.activePhase ?: @"starting",
      @"can_submit_code": @(canSubmit),
      @"expires_at": @((NSInteger)self.loginExpiresAt),
    } mutableCopy];
    if ([self.activePhase isEqualToString:@"verifying"]) [login removeObjectForKey:@"expires_at"];
    if (self.activeVerificationURL.length > 0) {
      login[@"verification_url"] = self.activeVerificationURL;
    }
    status[@"status"] = @"authorizing";
    status[@"auth_method"] = @"subscription";
    status[@"login"] = login;
    return status;
  }
  if (self.lastErrorCode.length > 0) {
    status[@"status"] = @"error";
    status[@"error_code"] = self.lastErrorCode;
    return status;
  }
  if (self.signedIn) {
    status[@"status"] = @"signed_in";
    status[@"auth_method"] = @"subscription";
  } else {
    // Never guessed: while guest truth is unknown the conservative answer is
    // signed_out; only a verified in-guest `auth status` sets signed_in.
    status[@"status"] = @"signed_out";
    status[@"auth_method"] = @"none";
  }
  return status;
}

- (NSDictionary *)status {
  @synchronized (self) {
    return [self statusSnapshotLocked];
  }
}

- (void)finishAsync:(void (^)(NSDictionary *))completion
             status:(NSDictionary *)status {
  if (completion == nil) return;
  dispatch_async(dispatch_get_main_queue(), ^{ completion(status); });
}

- (void)failActiveLoginWithCode:(NSString *)errorCode {
  [self recordDiagnostic:@"login_failed" details:@{@"error_code": errorCode ?: @"unknown"}];
  @synchronized (self) {
    self.activeSessionId = nil;
    self.activePhase = nil;
    self.activeVerificationURL = nil;
    self.activeExecutionID = nil;
    self.activeRequestID = nil;
    self.loginOutput = [NSMutableData data];
    self.lastErrorCode = errorCode;
  }
}

#pragma mark Guest control plumbing

- (NSDictionary *)performExchangeForPayload:(NSDictionary *)payload {
  __block NSDictionary *reply = nil;
  dispatch_sync(self.queue, ^{
    // The override seam and the FFI are untrusted boundaries; an exception
    // must never unwind through the actor's serial queue.
    @try {
      if (self.controlExchangeOverride) {
        reply = self.controlExchangeOverride(payload);
        return;
      }
      void *handle = NULL;
      @synchronized (self) { handle = self.vmHandle; }
      if (handle == NULL || rish_vm_session_control_json == NULL) return;
      NSData *encoded = [NSJSONSerialization dataWithJSONObject:payload
                                                        options:0 error:nil];
      if (encoded == nil) return;
      char *raw = rish_vm_session_control_json(
          handle, (const char *)encoded.bytes, encoded.length);
      if (raw == NULL) return;
      NSString *text = [NSString stringWithUTF8String:raw];
      rish_string_free(raw);
      if (text.length == 0 || text.length > DSHClaudeMaxReplyBytes) return;
      id parsed = [NSJSONSerialization
          JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding]
                    options:0 error:nil];
      if ([parsed isKindOfClass:NSDictionary.class]) reply = parsed;
      NSDictionary *kernel = [reply[@"exchange"] isKindOfClass:NSDictionary.class] ? reply[@"exchange"][@"diagnostics"] : nil;
      if ([kernel isKindOfClass:NSDictionary.class] &&
          ([kernel[@"kernel_oom"] boolValue] || [kernel[@"kernel_fault_lines"] count] > 0 ||
           [kernel[@"guest_termination_reasons"] count] > 0)) {
        [self recordDiagnostic:@"guest_kernel" details:kernel];
      }
      if ([reply[@"ok"] isEqual:@NO]) {
        // Only the FFI error, never command output, credentials, or OAuth URL.
        NSString *failure = [reply[@"error"] description] ?: @"control exchange failed";
        [self recordDiagnostic:@"control_failed" details:@{@"reason": [failure substringToIndex:MIN(failure.length, 1500)]}];
      }
    } @catch (NSException *) {
      reply = nil;
    }
  });
  return [DSHClaudeOfficialSession parseControlExchange:reply];
}

- (NSDictionary *)execPayloadForArgv:(NSArray<NSString *> *)argv
                                 env:(NSDictionary<NSString *, NSString *> *)env
                          attachStdin:(BOOL)attachStdin {
  return @{
    @"id": [NSString stringWithFormat:@"host-%@", NSUUID.UUID.UUIDString],
    @"operation": @"exec",
    @"parameters": [@{
      @"argv": argv,
      @"env": env,
      @"cwd": @"/",
      @"tty": @NO,
      @"attach_stdin": @(attachStdin),
      @"attach_stdout": @YES,
      @"attach_stderr": @YES,
      @"timeout_ms": @((uint64_t)(DSHClaudeLoginTimeout * 1000.0)),
    } mutableCopy],
  };
}

- (NSDictionary *)guestEnvironment {
  // Fully host-independent: no host environment, host HOME, or host tokens
  // are inherited by the guest process.
  return @{
    @"HOME": DSHClaudeGuestHome,
    @"CLAUDE_CONFIG_DIR": DSHClaudeGuestConfig,
    // This pinned binary has no scalar simdutf implementation. Select its
    // baseline explicitly without advertising unsupported CPU features.
    @"SIMDUTF_FORCE_IMPLEMENTATION": @"westmere",
    @"DISABLE_AUTOUPDATER": @"1",
    @"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": @"1",
    @"PATH": @"/usr/bin:/bin:/usr/sbin:/sbin:/opt/harness",
  };
}

/// Runs one guest command to completion with ~250ms ping polling (the VM only
/// advances while polled) under the 600s wall-clock contract. Returns
/// {exit_code, output} or nil. `login` routes captured output through the
/// bounded private login buffer and applies the login generation guard.
- (BOOL)ownsSession:(NSString *)session generation:(NSUInteger)generation {
  @synchronized (self) { return self.generation == generation && [self.activeSessionId isEqual:session]; }
}

- (NSDictionary *)runGuestCommand:(NSArray<NSString *> *)argv
                              env:(NSDictionary<NSString *, NSString *> *)env
                      attachStdin:(BOOL)attachStdin
                          timeout:(NSTimeInterval)timeout
                             login:(BOOL)login
                         loginFor:(NSString *)sessionId
                       generation:(NSUInteger)generation {
  BOOL guarded = sessionId != nil;
  [self recordDiagnostic:@"command_start" details:@{@"command": [argv componentsJoinedByString:@" "]}];
  if (guarded && ![self ownsSession:sessionId generation:generation]) return nil;
  NSDictionary *start = [self
      performExchangeForPayload:[self execPayloadForArgv:argv
                                                      env:env
                                              attachStdin:attachStdin]];
  NSMutableData *collected = [NSMutableData data];
  for (NSData *chunk in [start[@"streams"] isKindOfClass:NSArray.class] ? start[@"streams"] : @[]) {
    if (![chunk isKindOfClass:NSData.class] || chunk.length > DSHClaudeMaxOutputBytes - collected.length) return nil;
    [collected appendData:chunk];
    if (login) [self ingestLoginChunk:chunk];
  }
  NSString *executionID = [start[@"execution_id"] isKindOfClass:NSString.class]
      ? start[@"execution_id"] : nil;
  if (![start[@"ok"] boolValue] || executionID == nil) return nil;
  for (NSString *eventID in [start[@"event_execution_ids"] isKindOfClass:NSArray.class] ? start[@"event_execution_ids"] : @[]) {
    if (![eventID isEqualToString:executionID]) return nil;
  }
  NSString *requestID = [start[@"request_id"] isKindOfClass:NSString.class]
      ? start[@"request_id"] : nil;
  if (guarded) {
    @synchronized (self) {
      self.activeExecutionID = executionID;
      self.activeRequestID = requestID;
    }
  }
  if ([start[@"exited"] isKindOfClass:NSNumber.class]) {
    return @{ @"exit_code": start[@"exited"], @"output": [[NSString alloc] initWithData:collected encoding:NSUTF8StringEncoding] ?: @"" };
  }
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  NSNumber *exitCode = nil;
  while (YES) {
    NSTimeInterval remaining = [deadline timeIntervalSinceNow];
    if (login) {
      @synchronized (self) { remaining = self.loginExpiresAt - NSDate.date.timeIntervalSince1970; }
    }
    if (remaining <= 0) break;
    if (guarded && ![self ownsSession:sessionId generation:generation]) {
      [self cancelExecution:executionID requestID:requestID];
      return nil;
    }
    NSDictionary *ping = [self performExchangeForPayload:@{
      @"id": [NSString stringWithFormat:@"host-%@", NSUUID.UUID.UUIDString],
      @"operation": @"ping",
      @"parameters": @{ @"nonce": @"bounded" },
    }];
    if (![ping[@"ok"] boolValue]) {
      [self cancelExecution:executionID requestID:requestID];
      return nil;
    }
    for (NSString *eventID in [ping[@"event_execution_ids"] isKindOfClass:NSArray.class] ? ping[@"event_execution_ids"] : @[]) {
      if (![eventID isEqualToString:executionID]) {
        [self cancelExecution:executionID requestID:requestID];
        return nil;
      }
    }
    for (NSData *chunk in [ping[@"streams"] isKindOfClass:NSArray.class]
             ? ping[@"streams"] : @[]) {
      if (![chunk isKindOfClass:NSData.class]) continue;
      NSUInteger remaining = DSHClaudeMaxOutputBytes - collected.length;
      if (remaining == 0) break;
      [collected appendData:[chunk subdataWithRange:
          NSMakeRange(0, MIN(remaining, chunk.length))]];
      if (login) [self ingestLoginChunk:chunk];
    }
    if ([ping[@"exited"] isKindOfClass:NSNumber.class]) {
      exitCode = ping[@"exited"];
      break;
    }
    BOOL waitingForUser = NO;
    @synchronized (self) {
      waitingForUser = login && [self.activePhase isEqual:@"waiting_for_browser"];
    }
    // Polling advances the interpreter. A browser-wait interval during CLI
    // startup would starve guest execution and consume the login deadline.
    if (waitingForUser) [NSThread sleepForTimeInterval:DSHClaudePollInterval];
  }
  if (exitCode == nil) {
    [self cancelExecution:executionID requestID:requestID];
    return nil;
  }
  NSString *output = [[NSString alloc] initWithData:collected
                                           encoding:NSUTF8StringEncoding];
  return @{ @"exit_code": exitCode, @"output": output ?: @"" };
}

- (void)cancelExecution:(NSString *)executionID requestID:(NSString *)requestID {
  if (executionID == nil) return;
  NSDictionary *cancelled = [self performExchangeForPayload:@{
    @"id": [NSString stringWithFormat:@"host-%@", NSUUID.UUID.UUIDString],
    @"operation": @"cancel",
    @"parameters": (@{
      @"target_request_id": requestID ?: @"",
      @"execution_id": executionID,
      @"signal": @15,
    }),
  }];
  if (![cancelled[@"ok"] boolValue]) return;
  NSDate *deadline =
      [NSDate dateWithTimeIntervalSinceNow:DSHClaudeCancelPumpTimeout];
  while ([deadline timeIntervalSinceNow] > 0) {
    NSDictionary *ping = [self performExchangeForPayload:@{
      @"id": [NSString stringWithFormat:@"host-%@", NSUUID.UUID.UUIDString],
      @"operation": @"ping",
      @"parameters": @{ @"nonce": @"bounded" },
    }];
    if (![ping[@"ok"] boolValue] || [ping[@"exited"] isKindOfClass:NSNumber.class]) return;
    [NSThread sleepForTimeInterval:DSHClaudePollInterval];
  }
}

/// Bounded and private: only the allowlisted official verification URL is
/// ever extracted; nothing from this buffer is exposed outside the actor.
- (void)ingestLoginChunk:(NSData *)chunk {
  @synchronized (self) {
    if (!self.loginOutput) self.loginOutput = [NSMutableData data];
    NSUInteger remaining = DSHClaudeMaxOutputBytes - self.loginOutput.length;
    if (remaining == 0) return;
    [self.loginOutput appendData:[chunk subdataWithRange:
        NSMakeRange(0, MIN(remaining, chunk.length))]];
    NSString *text = [[NSString alloc] initWithData:self.loginOutput
                                           encoding:NSUTF8StringEncoding];
    if (text.length == 0) return;
    NSDictionary *fields = [DSHHarnessAuthService
        safeLoginFieldsFromOfficialOutput:text harnessId:DSHClaudeHarnessId];
    if ([fields[@"verification_url"] isKindOfClass:NSString.class]) {
      self.activeVerificationURL = fields[@"verification_url"];
    }
    if (self.activeVerificationURL.length > 0 &&
        [self.activePhase isEqualToString:@"starting"]) {
      self.activePhase = @"waiting_for_browser";
      // Human authorization gets its own budget after CLI startup completes.
      self.loginExpiresAt = NSDate.date.timeIntervalSince1970 + DSHClaudeBrowserTimeout;
    }
  }
}

#pragma mark Guest boot and disk

- (NSURL *)diskImageURL {
  return [self.storageDirectory
      URLByAppendingPathComponent:DSHClaudeDiskImageName];
}

/// Boots (or reuses) the guest, prepares the persistent guest HOME disk, and
/// mounts it at /mnt/claude. mkfs.vfat runs ONLY when the image file was
/// created by this call; an existing image that fails to mount fails closed —
/// it is never reformatted and its bytes are never inspected on the host.
- (BOOL)ensureGuestMountedWithError:(NSString **)errorCode {
  BOOL evictBeforeBoot = NO;
  @synchronized (self) {
    self.guestIdleEpoch += 1;
    if (self.vmHandle != NULL) {
      if (!self.guestEvictionRequested) return YES;
      evictBeforeBoot = YES;
    }
  }
  // A new request can register before the queued idle eviction runs. Honor
  // the pending memory-pressure eviction here before reusing its large VM.
  if (evictBeforeBoot) [self freeGuest];
  NSString *reason = nil;
  if (![self runtimeAvailableWithReason:&reason]) {
    if (errorCode) *errorCode = DSHClaudeErrorGuestBoot;
    return NO;
  }
  NSFileManager *manager = NSFileManager.defaultManager;
  if (![manager createDirectoryAtURL:self.storageDirectory withIntermediateDirectories:YES
      attributes:@{NSFileProtectionKey:NSFileProtectionComplete, NSFilePosixPermissions:@0700} error:nil] ||
      ![[manager attributesOfItemAtPath:self.storageDirectory.path error:nil][NSFileType] isEqual:NSFileTypeDirectory]) {
    if (errorCode) *errorCode = DSHClaudeErrorDiskFormat;
    return NO;
  }
  NSURL *diskURL = [self diskImageURL];
  BOOL createdNow = NO;
  if (![[NSFileManager defaultManager] fileExistsAtPath:diskURL.path]) {
    if (![[NSFileManager defaultManager]
             createFileAtPath:diskURL.path
                     contents:nil
                   attributes:@{
                         NSFileProtectionKey: NSFileProtectionComplete,
                         NSFilePosixPermissions: @0600,
                       }]) {
      if (errorCode) *errorCode = DSHClaudeErrorDiskFormat;
      return NO;
    }
    NSFileHandle *handle =
        [NSFileHandle fileHandleForWritingAtPath:diskURL.path];
    BOOL truncated =
        handle != nil && [handle truncateAtOffset:DSHClaudeDiskBytes
                                                 error:nil] &&
        [handle closeAndReturnError:nil];
    if (!truncated) {
      // Never leave a half-created image behind: it would otherwise be a
      // zero-byte "existing" image that can only fail closed later.
      [[NSFileManager defaultManager] removeItemAtURL:diskURL error:nil];
      if (errorCode) *errorCode = DSHClaudeErrorDiskFormat;
      return NO;
    }
    createdNow = YES;
  }
  [diskURL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
  [[NSFileManager defaultManager] setAttributes:@{
    NSFileProtectionKey: NSFileProtectionComplete,
    NSFilePosixPermissions: @0600,
  } ofItemAtPath:diskURL.path error:nil];
  chmod(diskURL.fileSystemRepresentation, 0600);

  NSDictionary *bootRequest = @{
    @"kernel_path": self.kernelURL.path,
    @"initrd_path": self.initrdURL.path,
    @"root_disk_path": diskURL.path,
    @"memory_mib": @1024,
    @"network": @"user-nat",
    @"command": @[],
    @"command_line":
        @"console=ttyS0,115200n8 rdinit=/init panic=-1 oops=panic nokaslr "
         @"cgroup_no_v1=all 8250.nr_uarts=1",
    @"boot_budget_units": @60000000000ULL,
    @"handshake_budget_units": @40000000000ULL,
  };
  void *handle = NULL;
  DSHGuestVMOwner *owner = [DSHGuestRuntimeState.sharedState acquireGuestOwner];
  if (!owner) {
    if (errorCode) *errorCode = @"E_GUEST_BUSY";
    return NO;
  }
  @synchronized (self) { self.vmOwner = owner; }
  @try {
  if (self.guestBootOverride) {
    if (!self.guestBootOverride(bootRequest)) {
      [DSHGuestRuntimeState.sharedState releaseGuestOwner:owner];
      @synchronized (self) { self.vmOwner = nil; }
      if (errorCode) *errorCode = DSHClaudeErrorGuestBoot;
      return NO;
    }
    handle = (__bridge void *)self;
  } else {
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:bootRequest
                                                      options:0 error:nil];
    handle = encoded == nil
        ? NULL
        : rish_vm_boot_session((const char *)encoded.bytes, encoded.length);
  }
  if (handle == NULL) {
    [DSHGuestRuntimeState.sharedState releaseGuestOwner:owner];
    @synchronized (self) { self.vmOwner = nil; }
    if (errorCode) *errorCode = DSHClaudeErrorGuestBoot;
    return NO;
  }
  @synchronized (self) { self.vmHandle = handle; }
  [DSHGuestRuntimeState.sharedState setGuestRuntimeMounted:YES owner:owner];

  if (createdNow) {
    NSDictionary *mkfs = [self runGuestCommand:@[ @"mkfs.vfat", @"/dev/vda" ]
                                              env:@{}
                                      attachStdin:NO
                                          timeout:60
                                             login:NO
                                         loginFor:nil
                                       generation:0];
    if (mkfs == nil || [mkfs[@"exit_code"] integerValue] != 0) {
      [self freeGuest];
      if (errorCode) *errorCode = DSHClaudeErrorDiskFormat;
      return NO;
    }
  }
  NSDictionary *mount = [self runGuestCommand:@[
    @"sh", @"-lc",
    [NSString stringWithFormat:@"ip link set lo up && mkdir -p %@ && mount -t vfat -o sync,fmask=0177,dmask=0077 /dev/vda %@ && mkdir -p %@",
                               DSHClaudeGuestMountPoint, DSHClaudeGuestMountPoint, DSHClaudeGuestHome],
  ]
                                              env:@{}
                                      attachStdin:NO
                                          timeout:60
                                             login:NO
                                         loginFor:nil
                                       generation:0];
  if (mount == nil || [mount[@"exit_code"] integerValue] != 0) {
    [self freeGuest];
    if (errorCode) *errorCode = DSHClaudeErrorDiskMount;
    return NO;
  }
  return YES;
  } @catch (__unused NSException *exception) {
    [self freeGuest];
    if (errorCode) *errorCode = DSHClaudeErrorGuestBoot;
    return NO;
  }
}

/// Routed through the serial queue so a release can never race an in-flight
/// control exchange using the same handle.
- (void)freeGuest {
  dispatch_sync(self.queue, ^{
    @synchronized (self) {
      if (self.vmHandle != NULL && !self.guestBootOverride) {
        rish_vm_session_free(self.vmHandle);
      }
      self.vmHandle = NULL;
      if (self.vmOwner) [DSHGuestRuntimeState.sharedState releaseGuestOwner:self.vmOwner];
      self.vmOwner = nil;
      self.guestIdleEpoch += 1;
      self.guestEvictionRequested = NO;
      self.cleanupPending = NO;
      self.activeExecutionID = nil;
      self.activeRequestID = nil;
    }
  });
}

#pragma mark Public API

- (void)startLogin:(void (^)(NSDictionary *))completion {
  dispatch_async(self.queue, ^{
    NSString *reason = nil;
    if (![self runtimeAvailableWithReason:&reason]) {
      [self finishAsync:completion status:self.status];
      return;
    }
    NSString *sessionId = nil;
    NSUInteger generation = 0;
    @synchronized (self) {
      if (self.activeTextRequestId.length > 0) {
        [self finishAsync:completion status:[self errorStatusLocked:DSHClaudeErrorTextBusy]];
        return;
      }
      if (DSHClaudeValidSessionId(self.activeSessionId)) {
        sessionId = self.activeSessionId;
      } else {
        self.generation =
            self.generation == NSUIntegerMax ? 1 : self.generation + 1;
        generation = self.generation;
        sessionId = NSUUID.UUID.UUIDString.lowercaseString;
        self.activeSessionId = sessionId;
        self.activePhase = @"starting";
        self.activeVerificationURL = nil;
        self.activeExecutionID = nil;
        self.activeRequestID = nil;
        self.lastErrorCode = nil;
        self.loginOutput = [NSMutableData data];
        self.loginExpiresAt =
            [NSDate date].timeIntervalSince1970 + DSHClaudeLoginTimeout;
      }
    }
    [self finishAsync:completion status:self.status];
    if (generation > 0) {
      [self watchLoginSession:sessionId generation:generation];
      dispatch_async(self.workerQueue, ^{
        [self runLoginForSession:sessionId generation:generation];
      });
    }
  });
}

// UI deadlines must not queue behind a synchronous interpreter exchange.
- (void)watchLoginSession:(NSString *)sessionId generation:(NSUInteger)generation {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    @synchronized (self) {
      if (self.generation != generation || ![self.activeSessionId isEqual:sessionId]) return;
      if (NSDate.date.timeIntervalSince1970 >= self.loginExpiresAt) {
        self.cleanupPending = YES;
        [self failActiveLoginWithCode:DSHClaudeErrorLoginTimeout];
        return;
      }
    }
    [self watchLoginSession:sessionId generation:generation];
  });
}

- (void)runLoginForSession:(NSString *)sessionId
                generation:(NSUInteger)generation {
  NSString *error = nil;
  if (![self ensureGuestMountedWithError:&error]) {
    if ([self ownsSession:sessionId generation:generation]) [self failActiveLoginWithCode:error ?: DSHClaudeErrorGuestBoot];
    return;
  }
  @synchronized (self) {
    if (self.generation == generation && [self.activeSessionId isEqual:sessionId]) self.loginExpiresAt = NSDate.date.timeIntervalSince1970 + DSHClaudeLoginTimeout;
  }
  NSDictionary *result = [self runGuestCommand:@[
    DSHClaudeGuestBinary, @"auth", @"login", @"--claudeai",
  ]
                                              env:[self guestEnvironment]
                                      attachStdin:YES
                                          timeout:DSHClaudeLoginTimeout
                                             login:YES
                                         loginFor:sessionId
                                       generation:generation];
  BOOL superseded = NO;
  @synchronized (self) {
    superseded = self.generation != generation ||
                 ![self.activeSessionId isEqualToString:sessionId];
  }
  if (superseded) {
    // Cancelled or superseded: the winner owns the snapshot and the handle.
    [self freeGuest];
    return;
  }
  if (result == nil || [result[@"exit_code"] integerValue] != 0) {
    if (result != nil) {
      NSString *output = [result[@"output"] isKindOfClass:NSString.class] ? result[@"output"] : @"";
      NSMutableArray *errors = [NSMutableArray array];
      for (NSString *line in [output componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *lower = line.lowercaseString;
        if (![lower containsString:@"error"] && ![lower containsString:@"failed"] &&
            ![lower containsString:@"exception"] && ![lower containsString:@"denied"]) continue;
        NSString *safe = line;
        for (NSString *pattern in @[@"https?://[^\\s]+", @"[A-Za-z0-9_.%+-]+@[A-Za-z0-9.-]+", @"[A-Za-z0-9_+/=-]{32,}"]) {
          NSRegularExpression *redactor = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
          safe = [redactor stringByReplacingMatchesInString:safe options:0 range:NSMakeRange(0, safe.length) withTemplate:@"[redacted]"];
        }
        [errors addObject:[safe substringToIndex:MIN(safe.length, 400)]];
        if (errors.count == 4) break;
      }
      [self recordDiagnostic:@"cli_exit" details:@{@"exit_code":result[@"exit_code"] ?: @(-1), @"errors":errors}];
      NSString *configurationPath = [DSHClaudeGuestConfig stringByAppendingPathComponent:@".claude.json"];
      NSString *corruption = [NSString stringWithFormat:@"Claude configuration file at %@ is corrupted: JSON Parse error", configurationPath];
      BOOL repair = NO;
      @synchronized (self) {
        if ([output containsString:corruption] && self.configurationRepairGeneration != generation &&
            self.generation == generation && [self.activeSessionId isEqual:sessionId]) {
          self.configurationRepairGeneration = generation;
          repair = YES;
        }
      }
      if (repair) {
        // Preserve the exact file diagnosed by the official CLI inside its
        // guest HOME. Credentials are neither read nor removed. Retry once.
        NSString *backup = [configurationPath stringByAppendingFormat:@".rish-backup-%@", NSUUID.UUID.UUIDString];
        NSDictionary *moved = [self runGuestCommand:@[@"sh", @"-lc",
          @"test -f \"$1\" && test ! -e \"$2\" && mv \"$1\" \"$2\" && sync",
          @"sh", configurationPath, backup]
          env:@{} attachStdin:NO timeout:60 login:NO loginFor:sessionId generation:generation];
        if ([moved[@"exit_code"] isKindOfClass:NSNumber.class] && [moved[@"exit_code"] integerValue] == 0 &&
            [self ownsSession:sessionId generation:generation]) {
          [self recordDiagnostic:@"configuration_backed_up" details:@{@"backup": backup}];
          @synchronized (self) { self.loginOutput = [NSMutableData data]; }
          [self runLoginForSession:sessionId generation:generation];
          return;
        }
      }
    }
    [self failActiveLoginWithCode:result == nil ? DSHClaudeErrorLoginTimeout : DSHClaudeErrorLoginFailed];
    [self freeGuest];
    return;
  }
  // ProcessExited alone is insufficient: only the official CLI's own status
  // command, parsed in the same guest, may move this actor to signed_in. No
  // credential files are read on the host or in the guest.
  @synchronized (self) {
    if ([self.activeSessionId isEqualToString:sessionId]) {
      self.activePhase = @"verifying";
          self.loginExpiresAt = NSDate.date.timeIntervalSince1970 + DSHClaudeLoginTimeout;
    }
  }
  NSDictionary *status = [self runGuestCommand:@[
    DSHClaudeGuestBinary, @"auth", @"status", @"--json",
  ]
                                              env:[self guestEnvironment]
                                      attachStdin:NO
                                          timeout:DSHClaudeLoginTimeout
                                             login:NO
                                         loginFor:sessionId
                                       generation:generation];
  if (![self ownsSession:sessionId generation:generation]) { [self freeGuest]; return; }
  BOOL verified = NO;
  if (status != nil && [status[@"exit_code"] integerValue] == 0) {
    NSData *data = [(NSString *)status[@"output"]
        dataUsingEncoding:NSUTF8StringEncoding];
    id parsed =
        data == nil
            ? nil
            : [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSDictionary *authStatus = [DSHClaudeOfficialSession
        authStatusFromGuestJSON:[parsed isKindOfClass:NSDictionary.class]
                                 ? parsed : nil];
    verified = [authStatus[@"subscription"] boolValue];
  }
  if (!verified) {
    [self failActiveLoginWithCode:DSHClaudeErrorLoginFailed];
    [self freeGuest];
    return;
  }
  // Sync the guest disk before publishing signed_in so credentials are
  // durable in the protected image; no credential bytes cross to the host.
  NSDictionary *synced = [self runGuestCommand:@[ @"sync" ]
                                           env:@{}
                                   attachStdin:NO
                                      timeout:60
                                        login:NO
                                      loginFor:nil
                                    generation:0];
  if (![self ownsSession:sessionId generation:generation]) { [self freeGuest]; return; }
  if (synced == nil || [synced[@"exit_code"] integerValue] != 0) {
    [self failActiveLoginWithCode:DSHClaudeErrorLoginFailed];
    [self freeGuest];
    return;
  }
  @synchronized (self) {
    if (self.generation == generation &&
        [self.activeSessionId isEqualToString:sessionId]) {
      self.activeSessionId = nil;
      self.activePhase = nil;
      self.activeVerificationURL = nil;
      self.activeExecutionID = nil;
      self.activeRequestID = nil;
      self.loginOutput = [NSMutableData data];
      self.lastErrorCode = nil;
      self.signedIn = YES;
      [self setRestoreHint:YES];
    }
  }
  [self freeGuest];
}

- (NSDictionary *)errorStatusLocked:(NSString *)errorCode {
  @synchronized (self) {
    self.lastErrorCode = errorCode;
    return [self statusSnapshotLocked];
  }
}

- (void)cancelSession:(NSString *)sessionId
           completion:(void (^)(NSDictionary *))completion {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    if (!DSHClaudeValidSessionId(sessionId)) {
      [self finishAsync:completion
                  status:[self errorStatusLocked:DSHClaudeErrorSessionInvalid]];
      return;
    }
    BOOL wasActive = NO;
    @synchronized (self) {
      wasActive = [self.activeSessionId isEqualToString:sessionId];
      if (wasActive) {
        self.cleanupPending = YES;
        // Generation bump stops the login worker's stale input immediately.
        self.generation =
            self.generation == NSUIntegerMax ? 1 : self.generation + 1;
        self.activeSessionId = nil;
        self.activePhase = nil;
        self.activeVerificationURL = nil;
        self.activeExecutionID = nil;
        self.activeRequestID = nil;
        self.loginOutput = [NSMutableData data];
        self.lastErrorCode = nil;
      }
    }
    if (wasActive) {
      dispatch_async(self.workerQueue, ^{
        [self freeGuest];
      });
    }
    [self finishAsync:completion status:self.status];
  });
}

- (void)submitCode:(NSString *)code
           session:(NSString *)sessionId
        completion:(void (^)(NSDictionary *))completion {
  dispatch_async(self.queue, ^{
    NSString *reason = nil;
    if (![self runtimeAvailableWithReason:&reason]) {
      [self finishAsync:completion status:self.status];
      return;
    }
    if (!DSHClaudeValidSessionId(sessionId)) {
      [self finishAsync:completion
                  status:[self errorStatusLocked:DSHClaudeErrorSessionInvalid]];
      return;
    }
    NSString *executionID = nil;
    @synchronized (self) {
      if (![self.activeSessionId isEqualToString:sessionId] ||
          self.activeExecutionID.length == 0) {
        [self finishAsync:completion
                    status:[self errorStatusLocked:DSHClaudeErrorSessionNotFound]];
        return;
      }
      executionID = self.activeExecutionID;
    }
    // Validated against injection (ASCII, single line, no control bytes) and
    // delivered only as base64 stdin bytes; argv and shell are never touched.
    NSString *validated = [DSHClaudeOfficialSession validatedLoginCode:code];
    if (validated == nil) {
      [self finishAsync:completion
                  status:[self errorStatusLocked:DSHClaudeErrorCodeInvalid]];
      return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSString *encoded = [[[validated stringByAppendingString:@"\n"]
          dataUsingEncoding:NSUTF8StringEncoding]
          base64EncodedStringWithOptions:0];
      @synchronized (self) {
        if (![self.activeSessionId isEqualToString:sessionId] ||
            ![self.activeExecutionID isEqualToString:executionID]) {
          [self finishAsync:completion status:[self statusSnapshotLocked]];
          return;
        }
      }
      NSDictionary *write = [self performExchangeForPayload:@{
        @"id": [NSString stringWithFormat:@"host-%@", NSUUID.UUID.UUIDString],
        @"operation": @"stream",
        @"parameters": @{
          @"execution_id": executionID,
          @"stream_action": @"write_stdin",
          @"data_base64": encoded,
        },
      }];
      if (![write[@"ok"] boolValue]) {
        [self finishAsync:completion status:[self errorStatusLocked:DSHClaudeErrorLoginFailed]];
        return;
      }
      @synchronized (self) {
        if ([self.activeSessionId isEqualToString:sessionId] &&
            [self.activePhase isEqualToString:@"waiting_for_browser"]) {
          self.activePhase = @"verifying";
          self.loginExpiresAt = NSDate.date.timeIntervalSince1970 + DSHClaudeLoginTimeout;
        }
      }
      [self finishAsync:completion status:self.status];
    });
  });
}

- (void)refresh:(void (^)(NSDictionary *))completion {
  dispatch_async(self.queue, ^{
    NSString *reason = nil;
    if (![self runtimeAvailableWithReason:&reason]) {
      [self finishAsync:completion status:self.status];
      return;
    }
    @synchronized (self) {
      if (DSHClaudeValidSessionId(self.activeSessionId) || self.activeTextRequestId.length > 0) {
        // A login is in flight; a refresh must never surface "authorizing"
        // for its own checking and never overlaps the guest's single command.
        [self finishAsync:completion status:[self statusSnapshotLocked]];
        return;
      }
    }
    dispatch_async(self.workerQueue, ^{
      @synchronized (self) { self.lastErrorCode = nil; }
      NSString *error = nil;
      if (![self ensureGuestMountedWithError:&error]) {
        [self finishAsync:completion
                    status:[self errorStatusLocked:error ?:
                                                    DSHClaudeErrorGuestBoot]];
        return;
      }
      NSDictionary *status = [self runGuestCommand:@[
        DSHClaudeGuestBinary, @"auth", @"status", @"--json",
      ]
                                                  env:[self guestEnvironment]
                                          attachStdin:NO
                                              timeout:DSHClaudeLoginTimeout
                                                 login:NO
                                             loginFor:nil
                                           generation:0];
      if (status == nil) {
        [self freeGuest];
        [self finishAsync:completion
                    status:[self errorStatusLocked:DSHClaudeErrorLoginTimeout]];
        return;
      }
      BOOL signedIn = NO;
      if (status != nil && [status[@"exit_code"] integerValue] == 0) {
        NSData *data = [(NSString *)status[@"output"]
            dataUsingEncoding:NSUTF8StringEncoding];
        id parsed = data == nil
            ? nil
            : [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *authStatus = [DSHClaudeOfficialSession
            authStatusFromGuestJSON:[parsed isKindOfClass:NSDictionary.class]
                                     ? parsed : nil];
        signedIn = [authStatus[@"subscription"] boolValue];
      }
      @synchronized (self) { self.signedIn = signedIn; }
      if (signedIn) [self setRestoreHint:YES];
      if (signedIn) [self retainHealthyGuestIfIdle];
      else [self freeGuest];
      [self finishAsync:completion status:self.status];
    });
  });
}

- (void)logout:(void (^)(NSDictionary *))completion {
  dispatch_async(self.queue, ^{
    NSString *reason = nil;
    if (![self runtimeAvailableWithReason:&reason]) {
      [self finishAsync:completion status:self.status];
      return;
    }
    @synchronized (self) {
      if (self.activeSessionId.length > 0 || self.activeTextRequestId.length > 0) {
        [self finishAsync:completion status:[self errorStatusLocked:DSHClaudeErrorTextBusy]];
        return;
      }
    }
    dispatch_async(self.workerQueue, ^{
      NSString *error = nil;
      BOOL guestOK = [self ensureGuestMountedWithError:&error];
      NSDictionary *result =
          guestOK ? [self runGuestCommand:@[ DSHClaudeGuestBinary,
                                             @"auth", @"logout" ]
                                         env:[self guestEnvironment]
                                 attachStdin:NO
                                     timeout:DSHClaudeLoginTimeout
                                        login:NO
                                    loginFor:nil
                                  generation:0]
                  : nil;
      if (result != nil) {
        // Sync after logout; the protected disk is never deleted/reformatted.
        [self runGuestCommand:@[ @"sync" ]
                          env:@{}
                  attachStdin:NO
                      timeout:60
                         login:NO
                     loginFor:nil
                   generation:0];
      }
      [self freeGuest];
      @synchronized (self) {
        self.signedIn = NO;
        if (result != nil && [result[@"exit_code"] integerValue] == 0) [self setRestoreHint:NO];
        self.activeSessionId = nil;
        self.activePhase = nil;
        self.activeVerificationURL = nil;
        self.activeExecutionID = nil;
        self.activeRequestID = nil;
        self.loginOutput = [NSMutableData data];
        self.lastErrorCode =
            (result != nil && [result[@"exit_code"] integerValue] == 0)
                ? nil
                : (error ?: DSHClaudeErrorLogoutFailed);
      }
      [self finishAsync:completion status:self.status];
    });
  });
}

#pragma mark Official CLI text completion

- (NSDictionary *)runGuestTextCommand:(NSString *)requestId
                                model:(NSString *)model
                               prompt:(NSString *)prompt
                         thinkingMode:(NSString *)thinkingMode
                           generation:(NSUInteger)generation {
  NSData *promptData = [prompt dataUsingEncoding:NSUTF8StringEncoding];
  if (promptData == nil || promptData.length == 0 ||
      promptData.length > DSHClaudeMaxPromptBytes) return nil;
  @synchronized (self) {
    if (self.textGeneration != generation ||
        ![self.activeTextRequestId isEqualToString:requestId]) return @{@"cancelled": @YES};
  }
  NSMutableArray *argv = [NSMutableArray arrayWithObject:DSHClaudeGuestBinary];
  [argv addObjectsFromArray:[DSHClaudeOfficialSession textArgumentsForModel:model thinkingMode:thinkingMode]];
  // The software guest clock is instruction-driven and can outrun host time.
  // The real text deadline is the native 600-second host timer below. Keep a
  // longer simulated-time guest watchdog as a secondary safety bound; auth
  // commands retain their existing guest timeout unchanged.
  NSMutableDictionary *textPayload = [[self execPayloadForArgv:argv
      env:[self guestEnvironment] attachStdin:YES] mutableCopy];
  NSMutableDictionary *textParameters = [textPayload[@"parameters"] mutableCopy];
  textParameters[@"timeout_ms"] = @1800000;
  textPayload[@"parameters"] = textParameters;
  NSDictionary *start = [self performExchangeForPayload:textPayload];
  NSString *executionID = [start[@"execution_id"] isKindOfClass:NSString.class]
      ? start[@"execution_id"] : nil;
  NSString *guestRequestID = [start[@"request_id"] isKindOfClass:NSString.class]
      ? start[@"request_id"] : nil;
  if (![start[@"ok"] boolValue] || executionID.length == 0) return nil;
  [self recordDiagnostic:@"text_process_started" details:@{}];
  NSMutableData *stdoutData = [NSMutableData data];
  NSMutableData *stderrData = [NSMutableData data];
  __block BOOL reportedFirstOutput = NO;
  __block NSNumber *eventExit = nil;
  __block NSNumber *eventSignal = nil;
  BOOL (^consume)(NSDictionary *) = ^BOOL(NSDictionary *exchange) {
    if (![exchange[@"ok"] boolValue]) return NO;
    for (NSString *eventID in exchange[@"event_execution_ids"] ?: @[]) {
      if (![eventID isEqualToString:executionID]) return NO;
    }
    for (NSData *chunk in exchange[@"stdout_streams"] ?: @[]) {
      if (stdoutData.length + chunk.length > DSHClaudeMaxOutputBytes) return NO;
      if (!reportedFirstOutput && chunk.length > 0) {
        reportedFirstOutput = YES;
        [self recordDiagnostic:@"text_first_output" details:@{}];
      }
      [stdoutData appendData:chunk];
    }
    for (NSData *chunk in exchange[@"stderr_streams"] ?: @[]) {
      if (stderrData.length + chunk.length > DSHClaudeMaxOutputBytes) return NO;
      if (!reportedFirstOutput && chunk.length > 0) {
        reportedFirstOutput = YES;
        [self recordDiagnostic:@"text_first_output" details:@{}];
      }
      [stderrData appendData:chunk];
    }
    if ([exchange[@"exited"] isKindOfClass:NSNumber.class]) eventExit = exchange[@"exited"];
    if ([exchange[@"signal"] isKindOfClass:NSNumber.class]) eventSignal = exchange[@"signal"];
    return YES;
  };
  if (!consume(start)) return nil;
  const NSUInteger chunkBytes = 48 * 1024;
  if (eventExit == nil) for (NSUInteger offset = 0; offset < promptData.length; offset += chunkBytes) {
    BOOL owns = NO;
    @synchronized (self) { owns = self.textGeneration == generation && [self.activeTextRequestId isEqualToString:requestId]; }
    if (!owns) { [self cancelExecution:executionID requestID:guestRequestID]; return @{@"cancelled": @YES}; }
    NSUInteger length = MIN(chunkBytes, promptData.length - offset);
    NSString *encoded = [[promptData subdataWithRange:NSMakeRange(offset, length)] base64EncodedStringWithOptions:0];
    NSDictionary *write = [self performExchangeForPayload:@{
      @"id": [NSString stringWithFormat:@"host-%@", NSUUID.UUID.UUIDString], @"operation": @"stream",
      @"parameters": @{ @"execution_id": executionID, @"stream_action": @"write_stdin", @"data_base64": encoded ?: @"" }
    }];
    if (!consume(write)) { [self cancelExecution:executionID requestID:guestRequestID]; return nil; }
    if (eventExit != nil) break;
  }
  if (eventExit == nil) {
    NSDictionary *close = [self performExchangeForPayload:@{
      @"id": [NSString stringWithFormat:@"host-%@", NSUUID.UUID.UUIDString], @"operation": @"stream",
      @"parameters": @{ @"execution_id": executionID, @"stream_action": @"close_stdin" }
    }];
    if (!consume(close)) { [self cancelExecution:executionID requestID:guestRequestID]; return nil; }
    [self recordDiagnostic:@"text_input_closed" details:@{}];
  }
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:DSHClaudeTextTimeout];
  NSNumber *exitCode = eventExit;
  while (exitCode == nil && [deadline timeIntervalSinceNow] > 0) {
    BOOL owns = NO;
    @synchronized (self) {
      owns = self.textGeneration == generation && [self.activeTextRequestId isEqualToString:requestId];
    }
    if (!owns) { [self cancelExecution:executionID requestID:guestRequestID]; return @{@"cancelled": @YES}; }
    NSDictionary *ping = [self performExchangeForPayload:@{
      @"id": [NSString stringWithFormat:@"host-%@", NSUUID.UUID.UUIDString],
      @"operation": @"ping", @"parameters": @{ @"nonce": @"bounded" }
    }];
    if (!consume(ping)) break;
    if (eventExit != nil) { exitCode = eventExit; break; }
  }
  if (exitCode == nil) {
    [self cancelExecution:executionID requestID:guestRequestID];
    return @{ @"timeout": @YES, @"stdout": [[NSString alloc] initWithData:stdoutData encoding:NSUTF8StringEncoding] ?: @"", @"stderr": [[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding] ?: @"" };
  }
  NSString *stdoutText = [[NSString alloc] initWithData:stdoutData encoding:NSUTF8StringEncoding];
  NSString *stderrText = [[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding];
  BOOL owns = NO;
  @synchronized (self) { owns = self.textGeneration == generation && [self.activeTextRequestId isEqualToString:requestId]; }
  if (!owns) return @{@"cancelled": @YES};
  return @{ @"exit_code": exitCode, @"signal": eventSignal ?: NSNull.null, @"stdout": stdoutText ?: @"", @"stderr": stderrText ?: @"" };
}

- (void)completeTextRequest:(NSDictionary *)request
                 completion:(void (^)(NSDictionary *, NSString *))completion {
  dispatch_async(self.queue, ^{
    NSString *requestId = [request[@"request_id"] isKindOfClass:NSString.class] ? request[@"request_id"] : nil;
    NSString *model = [request[@"model"] isKindOfClass:NSString.class] ? request[@"model"] : nil;
    NSString *prompt = [request[@"prompt"] isKindOfClass:NSString.class] ? request[@"prompt"] : nil;
    NSString *thinkingMode = request[@"thinking_mode"] ?: @"off";
    NSData *promptData = [prompt dataUsingEncoding:NSUTF8StringEncoding];
    BOOL safeModel = model.length > 0;
    for (NSUInteger i = 0; i < model.length; i++) {
      unichar c = [model characterAtIndex:i];
      if (c < 0x21 || c > 0x7e) { safeModel = NO; break; }
    }
    if (request.count != (request[@"thinking_mode"] == nil ? 3 : 4) ||
        [DSHClaudeOfficialSession textArgumentsForModel:model thinkingMode:thinkingMode].count == 0 || requestId.length == 0 || requestId.length > 128 ||
        !safeModel || model.length > 128 || promptData.length == 0 ||
        promptData.length > DSHClaudeMaxPromptBytes ||
        [requestId rangeOfString:@"\0"].location != NSNotFound ||
        [model rangeOfString:@"\0"].location != NSNotFound) {
      if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, DSHClaudeErrorTextInvalid); });
      return;
    }
    NSString *reason = nil;
    if (![self runtimeAvailableWithReason:&reason]) { if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, reason ?: DSHClaudeErrorGuestBoot); }); return; }
    @synchronized (self) {
      if (!self.signedIn || self.cleanupPending) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, DSHClaudeErrorTextAuthRequired); });
        return;
      }
      if (self.activeSessionId.length > 0 || self.activeTextRequestId.length > 0) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, DSHClaudeErrorTextBusy); });
        return;
      }
      if ([self.pendingTextCancels containsObject:requestId]) {
        [self.pendingTextCancels removeObject:requestId];
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, DSHClaudeErrorTextCancelled); });
        return;
      }
      self.textGeneration = self.textGeneration == NSUIntegerMax ? 1 : self.textGeneration + 1;
      self.activeTextRequestId = requestId;
    }
    NSUInteger generation = self.textGeneration;
    [self recordDiagnostic:@"text_start" details:@{@"request_id":requestId, @"model":model, @"input_bytes":@(promptData.length)}];
    dispatch_async(self.workerQueue, ^{
      @synchronized (self) {
        if (self.textGeneration != generation ||
            ![self.activeTextRequestId isEqualToString:requestId]) {
          if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, DSHClaudeErrorTextCancelled); });
          return;
        }
      }
      NSString *mountError = nil;
      BOOL mounted = [self ensureGuestMountedWithError:&mountError];
      if (mounted) [self recordDiagnostic:@"text_guest_ready" details:@{}];
      NSDictionary *raw = mounted
          ? [self runGuestTextCommand:requestId model:model prompt:prompt thinkingMode:thinkingMode generation:generation] : nil;
      NSDictionary *result = nil;
      NSString *error = nil;
      if ([raw[@"cancelled"] boolValue]) error = DSHClaudeErrorTextCancelled;
      else if ([raw[@"timeout"] boolValue]) error = DSHClaudeErrorTextTimeout;
      else if (raw == nil || [raw[@"exit_code"] integerValue] != 0) error = mountError ?: DSHClaudeErrorTextFailed;
      else {
        NSData *data = [raw[@"stdout"] dataUsingEncoding:NSUTF8StringEncoding];
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        result = [DSHClaudeOfficialSession normalizedTextResultFromJSON:json model:model];
        if (result != nil && [result[@"provider_response_id"] length] == 0) {
          NSMutableDictionary *withRequestId = [result mutableCopy];
          withRequestId[@"provider_response_id"] = requestId;
          result = withRequestId;
        }
        if (result == nil) error = DSHClaudeErrorTextFailed;
      }
      NSMutableArray *errorTerms = [NSMutableArray array];
      NSMutableArray *errorSummaries = [NSMutableArray array];
      NSNumber *apiErrorStatus = nil;
      BOOL completedResult = result != nil;
      if (error != nil) {
        NSString *output = [NSString stringWithFormat:@"%@ %@", raw[@"stdout"] ?: @"", raw[@"stderr"] ?: @""];
        for (NSString *term in @[@"invalid model", @"not logged in", @"authentication", @"rate limit", @"credit balance", @"unknown option", @"permission denied", @"ECONNREFUSED", @"certificate", @"timeout", @"JSON Parse error"]) {
          if ([output rangeOfString:term options:NSCaseInsensitiveSearch].location != NSNotFound) [errorTerms addObject:term];
        }
        NSData *jsonData = [raw[@"stdout"] dataUsingEncoding:NSUTF8StringEncoding];
        id failure = jsonData ? [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil] : nil;
        if ([failure isKindOfClass:NSDictionary.class]) {
          completedResult = [failure[@"type"] isEqual:@"result"] && [failure[@"subtype"] isEqual:@"success"] &&
              [failure[@"is_error"] isEqual:@NO] && [failure[@"result"] isKindOfClass:NSString.class];
        }
        NSMutableArray *messages = [NSMutableArray array];
        if ([failure isKindOfClass:NSDictionary.class] && [failure[@"type"] isEqual:@"result"] && [failure[@"is_error"] isEqual:@YES]) {
          // Print mode may place its API error in `result`, without `errors`.
          // Apply the same bounded redaction used for the error array.
          if ([failure[@"result"] isKindOfClass:NSString.class]) [messages addObject:failure[@"result"]];
          if ([failure[@"errors"] isKindOfClass:NSArray.class]) [messages addObjectsFromArray:failure[@"errors"]];
          id status = failure[@"api_error_status"];
          if ([status isKindOfClass:NSNumber.class] && [status doubleValue] == [status integerValue] &&
              [status integerValue] >= 100 && [status integerValue] <= 599) apiErrorStatus = status;
        }
        for (id message in messages) {
          if (![message isKindOfClass:NSString.class]) continue;
          NSString *safe = message;
          for (NSString *pattern in @[@"https?://[^\\s]+", @"[A-Za-z0-9_.%+-]+@[A-Za-z0-9.-]+", @"[A-Za-z0-9_+/=-]{32,}"]) {
            NSRegularExpression *redactor = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
            safe = [redactor stringByReplacingMatchesInString:safe options:0 range:NSMakeRange(0,safe.length) withTemplate:@"[redacted]"];
          }
          [errorSummaries addObject:[safe substringToIndex:MIN(safe.length,400)]];
          if (errorSummaries.count == 4) break;
        }
      }
      [self recordDiagnostic:@"text_finished" details:@{@"request_id":requestId, @"error_code":error ?: @"", @"exit_code":raw[@"exit_code"] ?: @(-1), @"signal":raw[@"signal"] ?: NSNull.null, @"completed_result":@(completedResult), @"stdout_bytes":@([raw[@"stdout"] lengthOfBytesUsingEncoding:NSUTF8StringEncoding]), @"stderr_bytes":@([raw[@"stderr"] lengthOfBytesUsingEncoding:NSUTF8StringEncoding]), @"error_terms":errorTerms, @"errors":errorSummaries, @"api_error_status":apiErrorStatus ?: (id)NSNull.null}];
      BOOL healthyOwner = NO;
      @synchronized (self) {
        healthyOwner = self.textGeneration == generation && [self.activeTextRequestId isEqualToString:requestId];
        if (healthyOwner) self.activeTextRequestId = nil;
      }
      if (error == nil && result != nil && healthyOwner) [self retainHealthyGuestIfIdle];
      else [self freeGuest];
      if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(result, error); });
    });
  });
}

- (void)cancelTextRequest:(NSString *)requestId {
  if (![requestId isKindOfClass:NSString.class]) return;
  @synchronized (self) {
    if (![self.activeTextRequestId isEqualToString:requestId]) {
      if (self.pendingTextCancels.count < 32) [self.pendingTextCancels addObject:requestId];
      return;
    }
    self.textGeneration = self.textGeneration == NSUIntegerMax ? 1 : self.textGeneration + 1;
    self.activeTextRequestId = nil;
  }
}

#pragma mark Pure seams

+ (NSDictionary *)parseControlExchange:(NSDictionary *)exchange {
  NSMutableDictionary *normalized = [NSMutableDictionary dictionary];
  if (![exchange isKindOfClass:NSDictionary.class] || exchange.count != 3 ||
      ![exchange[@"protocol_version"] isEqual:@1] ||
      ![exchange[@"ok"] isKindOfClass:NSNumber.class] ||
      ![exchange[@"exchange"] isKindOfClass:NSDictionary.class]) return normalized;
  if (![exchange[@"ok"] boolValue]) { normalized[@"ok"] = @NO; return normalized; }
  normalized[@"ok"] = @YES;
  NSDictionary *body = exchange[@"exchange"];
  NSDictionary *response = body[@"response"];
  if (![response isKindOfClass:NSDictionary.class] || response.count != 3 ||
      ![response[@"id"] isKindOfClass:NSString.class] ||
      ![response[@"status"] isEqual:@"success"] ||
      ![response[@"result"] isKindOfClass:NSDictionary.class]) return @{};
  normalized[@"request_id"] = response[@"id"];
  NSDictionary *result = response[@"result"];
  if (result.count == 2 && [result[@"result_type"] isEqual:@"exec_started"] &&
      [result[@"result"] isKindOfClass:NSDictionary.class] &&
      [result[@"result"][ @"execution_id"] isKindOfClass:NSString.class]) {
    normalized[@"execution_id"] = result[@"result"][ @"execution_id"];
  }
  NSArray *events = body[@"events"];
  if (![events isKindOfClass:NSArray.class]) return @{};
  {
    NSMutableArray *streams = [NSMutableArray array];
    NSMutableArray *stdoutStreams = [NSMutableArray array];
    NSMutableArray *stderrStreams = [NSMutableArray array];
    NSMutableArray *eventExecutionIDs = [NSMutableArray array];
    NSUInteger streamBytes = 0;
    BOOL sawExit = NO;
    for (id item in events) {
      if (![item isKindOfClass:NSDictionary.class]) return @{};
      NSDictionary *event = item;
      NSString *kind = event[@"event_type"];
      NSDictionary *source = event[@"event"];
      if (![kind isKindOfClass:NSString.class] ||
          ![source isKindOfClass:NSDictionary.class] ||
          ![source[@"execution_id"] isKindOfClass:NSString.class]) return @{};
      [eventExecutionIDs addObject:source[@"execution_id"]];
      if ([kind isEqualToString:@"stream"]) {
        if (source.count != 5 || ![source[@"data_base64"] isKindOfClass:NSString.class]) return @{};
        NSData *data = [[NSData alloc] initWithBase64EncodedString:source[@"data_base64"] options:0];
        if (data == nil || data.length > DSHClaudeMaxOutputBytes - streamBytes) return @{};
        streamBytes += data.length;
        [streams addObject:data];
        NSString *channel = source[@"channel"];
        if ([channel isEqualToString:@"stdout"]) [stdoutStreams addObject:data];
        else if ([channel isEqualToString:@"stderr"]) [stderrStreams addObject:data];
        else return @{};
      } else if ([kind isEqualToString:@"process_exited"]) {
        if (source.count != 3) return @{};
        if ([source[@"exit_code"] isKindOfClass:NSNumber.class]) {
          normalized[@"exited"] = source[@"exit_code"];
        } else if (source[@"exit_code"] == NSNull.null &&
                   [source[@"signal"] isKindOfClass:NSNumber.class] &&
                   [source[@"signal"] integerValue] > 0 && [source[@"signal"] integerValue] <= 64) {
          normalized[@"exited"] = @(-1);
          normalized[@"signal"] = source[@"signal"];
        } else return @{};
        sawExit = YES;
      } else if ([kind isEqualToString:@"execution_started"]) {
        if (source.count != 2 || ![source[@"pid"] isKindOfClass:NSNumber.class]) return @{};
      } else {
        return @{};
      }
    }
    if (streams.count > 0) normalized[@"streams"] = streams;
    if (stdoutStreams.count > 0) normalized[@"stdout_streams"] = stdoutStreams;
    if (stderrStreams.count > 0) normalized[@"stderr_streams"] = stderrStreams;
    if (eventExecutionIDs.count > 0) normalized[@"event_execution_ids"] = eventExecutionIDs;
    if (sawExit && normalized[@"exited"] == nil) normalized[@"exited"] = @0;
  }
  return normalized;
}

+ (NSDictionary *)authStatusFromGuestJSON:(NSDictionary *)json {
  if (![json isKindOfClass:NSDictionary.class]) {
    return @{ @"logged_in": @NO, @"subscription": @NO, @"auth_method": @"" };
  }
  BOOL loggedIn = NO;
  for (NSString *key in @[ @"loggedIn", @"logged_in", @"authenticated" ]) {
    if ([json[key] isKindOfClass:NSNumber.class]) {
      loggedIn = [json[key] boolValue];
      break;
    }
  }
  NSString *method = nil;
  for (NSString *key in @[ @"authMethod", @"auth_method", @"method" ]) {
    if ([json[key] isKindOfClass:NSString.class]) {
      method = json[key];
      break;
    }
  }
  NSString *lower = method.lowercaseString ?: @"";
  BOOL subscription =
      loggedIn && ([lower containsString:@"claude.ai"] ||
                   [lower isEqualToString:@"subscription"]);
  return @{
    @"logged_in": @(loggedIn),
    @"subscription": @(subscription),
    @"auth_method": method ?: @"",
  };
}

+ (NSString *)validatedLoginCode:(NSString *)code {
  if (![code isKindOfClass:NSString.class]) return nil;
  NSUInteger length = code.length;
  if (length == 0 || length > DSHClaudeMaxCodeLength) return nil;
  for (NSUInteger index = 0; index < length; index += 1) {
    unichar character = [code characterAtIndex:index];
    if (character < 0x20 || character > 0x7e) return nil;
  }
  return code;
}

+ (NSDictionary *)normalizedTextResultFromJSON:(id)json model:(NSString *)model {
  if (![json isKindOfClass:NSDictionary.class] || model.length == 0) return nil;
  NSDictionary *object = json;
  if (![object[@"type"] isEqualToString:@"result"] ||
      ![object[@"subtype"] isEqualToString:@"success"] ||
      ![object[@"is_error"] isKindOfClass:NSNumber.class] ||
      [object[@"is_error"] boolValue]) return nil;
  NSString *text = [object[@"result"] isKindOfClass:NSString.class] ? object[@"result"] : nil;
  if (text == nil) return nil;
  NSString *actualModel = [object[@"model"] isKindOfClass:NSString.class] ? object[@"model"] : nil;
  NSDictionary *usage = [object[@"modelUsage"] isKindOfClass:NSDictionary.class] ? object[@"modelUsage"] : nil;
  if (actualModel == nil && usage.count == 1) actualModel = usage.allKeys.firstObject;
  if (actualModel == nil || ![actualModel isEqualToString:model]) return nil;
  NSString *responseId = nil;
  for (NSString *key in @[@"provider_response_id", @"message_id", @"uuid", @"session_id", @"id"]) {
    if ([object[key] isKindOfClass:NSString.class] && [object[key] length] > 0) {
      responseId = object[key]; break;
    }
  }
  if (responseId == nil) responseId = @"";
  return @{ @"provider_response_id": responseId,
            @"model": actualModel,
            @"text": text,
            @"reasoning": @"",
            @"tool_calls": @[],
            @"finish_reason": @"stop" };
}

+ (NSArray<NSString *> *)textArgumentsForModel:(NSString *)model {
  return [self textArgumentsForModel:model thinkingMode:@"off"];
}

+ (NSArray<NSString *> *)textArgumentsForModel:(NSString *)model thinkingMode:(NSString *)thinkingMode {
  if (![model isKindOfClass:NSString.class] || model.length == 0 ||
      ![@[@"off", @"low", @"medium", @"high", @"max"] containsObject:thinkingMode ?: NSNull.null]) return @[];
  BOOL thinking = ![thinkingMode isEqualToString:@"off"];
  NSMutableArray *arguments = [@[@"-p", @"--safe-mode", @"--output-format", @"json", @"--tools=", @"--max-turns", @"1",
           @"--no-session-persistence", @"--strict-mcp-config",
           @"--mcp-config", @"{\"mcpServers\":{}}", @"--setting-sources=",
           @"--settings", thinking ? @"{\"alwaysThinkingEnabled\":true}" : @"{\"alwaysThinkingEnabled\":false}",
           @"--model", model] mutableCopy];
  if (thinking) [arguments addObjectsFromArray:@[@"--effort", thinkingMode]];
  return arguments;
}

@end
