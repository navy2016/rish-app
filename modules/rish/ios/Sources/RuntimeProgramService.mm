#import "RuntimeProgramService.h"
#import "RuntimeProgramServiceVM.h"
#import "RuntimeWorkspaceSnapshot.h"
#import "RuntimeEnvironmentStore.h"
#import "AgentNativeWAL.h"
#import "AgentRootResolver.h"
#import "ProjectContextService.h"
#import "SessionWorkspaceCoordinator.h"
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>

@interface DSHProjectContextService (DSHProgramComposition)
@property(nonatomic, strong, readonly) DSHLocalProjectAccess *projectAccess;
@property(nonatomic, strong, readonly) DSHLocalWorkspaceAccess *workspaceAccess;
@end

@interface DSHProgramRun : NSObject
@property(nonatomic, copy) NSString *runId;
@property(nonatomic, copy) NSDictionary *request;
@property(nonatomic, copy) NSString *status;
@property(nonatomic, strong) NSMutableData *stdoutData;
@property(nonatomic, strong) NSMutableData *stderrData;
@property(nonatomic) BOOL stdoutTruncated;
@property(nonatomic) BOOL stderrTruncated;
@property(nonatomic, strong) NSNumber *exitCode;
@property(nonatomic, copy) NSString *errorCode;
@property(nonatomic, strong) DSHRuntimeProgramVM *vm;
@end
@implementation DSHProgramRun
@end

static BOOL ValidStart(id request) {
  if (!DSHAgentExactDictionaryKeys(request, @[@"schema_version", @"operation_id", @"root",
      @"environment_id", @"entry_path", @"args"]) ||
      !DSHAgentSafeInteger(request[@"schema_version"], 1, NO) ||
      !DSHAgentCanonicalUUID(request[@"operation_id"]) || !DSHRuntimeProgramValidRoot(request[@"root"]) ||
      !DSHRuntimeProgramValidPath(request[@"entry_path"])) return NO;
  // This is looser than DSHEnvironmentValidId, which anchors the first
  // character: a membership test accepts "-python" and "---". No catalogued
  // environment can carry such an id, so a start naming one fails later as a
  // missing environment rather than an invalid request. The difference is
  // pinned in the core's tests so that unifying the two is a decision someone
  // makes, not a side effect. See runtime_environment::valid_program_environment_id.
  if (!DSHRuntimeProgramValidEnvironmentId(request[@"environment_id"])) return NO;
  NSArray *args = request[@"args"];
  if (![args isKindOfClass:NSArray.class] || args.count > 64) return NO;
  NSUInteger total = 0;
  for (NSString *arg in args) {
    if (![arg isKindOfClass:NSString.class] || [arg containsString:@"\0"]) return NO;
    NSData *utf8 = [arg dataUsingEncoding:NSUTF8StringEncoding];
    if (utf8 == nil || utf8.length > 4096 || utf8.length > 65536 - total) return NO;
    total += utf8.length;
  }
  return YES;
}

static BOOL ValidLocator(id request) {
  return DSHAgentExactDictionaryKeys(request, @[@"schema_version", @"run_id"]) &&
      DSHAgentSafeInteger(request[@"schema_version"], 1, NO) && DSHAgentCanonicalUUID(request[@"run_id"]);
}

static NSString *RequestDigest(NSDictionary *request) {
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:request options:NSJSONWritingSortedKeys error:nil];
  if (!bytes) return nil;
  uint8_t digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
  NSMutableString *hex = [NSMutableString string];
  for (NSUInteger i = 0; i < sizeof(digest); i++) [hex appendFormat:@"%02x", digest[i]];
  return hex;
}

static NSString *DecodeOutput(NSData *data, BOOL *truncated) {
  // Stream chunks can split UTF-8 codepoints. Decode the complete retained
  // prefix; replacement decoding also makes arbitrary binary stdout safe.
  if (data.length == 0) return @"";
  NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if (text != nil) return text;
  NSMutableString *result = [NSMutableString string];
  const uint8_t *bytes = (const uint8_t *)data.bytes;
  NSUInteger encodedBytes = 0;
  for (NSUInteger offset = 0; offset < data.length;) {
    NSUInteger width = bytes[offset] < 0x80 ? 1 : bytes[offset] < 0xe0 ? 2 : bytes[offset] < 0xf0 ? 3 : 4;
    NSString *piece = offset + width <= data.length ? [[NSString alloc]
        initWithBytes:bytes + offset length:width encoding:NSUTF8StringEncoding] : nil;
    NSString *replacement = piece ?: @"�";
    NSUInteger cost = [replacement lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (cost > 262144 - encodedBytes) { *truncated = YES; break; }
    [result appendString:replacement]; encodedBytes += cost;
    offset += piece != nil ? width : 1;
  }
  return result;
}

@interface DSHRuntimeProgramService ()
@property(nonatomic, strong) DSHAgentRootResolver *resolver;
@property(nonatomic, strong) DSHRuntimeEnvironmentStore *store;
@property(nonatomic, copy) DSHRuntimeProgramVMFactory factory;
@property(nonatomic, strong) dispatch_queue_t worker;
@property(nonatomic, strong) NSMutableDictionary<NSString *, DSHProgramRun *> *runs;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *operations;
@property(nonatomic, strong) NSMutableArray<NSString *> *runOrder;
@property(nonatomic, strong) DSHProgramRun *active;
@property(nonatomic) BOOL backgrounded;
@end

@implementation DSHRuntimeProgramService
+ (instancetype)sharedService {
  static DSHRuntimeProgramService *service;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    DSHProjectContextService *context = DSHSharedProjectContextService();
    DSHAgentRootResolver *resolver = [[DSHAgentRootResolver alloc]
        initWithWorkspaceAccess:context.workspaceAccess projectAccess:context.projectAccess];
    service = [[self alloc] initWithResolver:resolver store:DSHRuntimeEnvironmentStore.sharedStore
        vmFactory:^{ return [[DSHRuntimeProgramVM alloc] initWithBundle:NSBundle.mainBundle]; }];
  });
  return service;
}
- (instancetype)initWithResolver:(DSHAgentRootResolver *)resolver store:(DSHRuntimeEnvironmentStore *)store
                       vmFactory:(DSHRuntimeProgramVMFactory)factory {
  self = [super init];
  if (self) {
    _resolver = resolver; _store = store; _factory = [factory copy];
    _runs = [NSMutableDictionary dictionary]; _operations = [NSMutableDictionary dictionary];
    _runOrder = [NSMutableArray array];
    _worker = dispatch_queue_create("tech.zseven.rish.program-worker",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(cancelForBackground)
        name:UIApplicationDidEnterBackgroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(enteredForeground)
        name:UIApplicationWillEnterForegroundNotification object:nil];
  }
  return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)enteredForeground { @synchronized (self) { self.backgrounded = NO; } }
- (NSDictionary *)receipt:(DSHProgramRun *)run {
  BOOL stdoutTruncated = run.stdoutTruncated, stderrTruncated = run.stderrTruncated;
  NSString *stdoutText = DecodeOutput(run.stdoutData, &stdoutTruncated);
  NSString *stderrText = DecodeOutput(run.stderrData, &stderrTruncated);
  return @{@"schema_version":@1, @"run_id":run.runId,
    @"workspace_id":run.request[@"root"][@"workspace_id"],
    @"environment_id":run.request[@"environment_id"], @"status":run.status,
    @"stdout":stdoutText, @"stderr":stderrText,
    @"stdout_truncated":@(stdoutTruncated), @"stderr_truncated":@(stderrTruncated),
    @"exit_code":run.exitCode ?: NSNull.null, @"error_code":run.errorCode ?: NSNull.null};
}
- (NSDictionary *)startRequest:(id)request error:(NSError **)error {
  @try {
    if (!ValidStart(request)) { if (error) *error = DSHRuntimeProgramError(@"E_PROGRAM_INVALID_REQUEST"); return nil; }
    NSDictionary *immutable = DSHAgentImmutableJSONCopy(request, nil);
    if (immutable == nil) { if (error) *error = DSHRuntimeProgramError(@"E_PROGRAM_INVALID_REQUEST"); return nil; }
    NSString *digest = RequestDigest(immutable);
    if (digest == nil) { if (error) *error = DSHRuntimeProgramError(@"E_PROGRAM_INVALID_REQUEST"); return nil; }
    @synchronized (self) {
      NSDictionary *existing = self.operations[immutable[@"operation_id"]];
      if (existing) {
        if (![existing[@"request_sha256"] isEqual:digest]) {
          if (error) *error = DSHRuntimeProgramError(@"E_PROGRAM_OPERATION_CONFLICT"); return nil;
        }
        DSHProgramRun *run = self.runs[existing[@"run_id"]];
        if (!run) { if (error) *error = DSHRuntimeProgramError(@"E_PROGRAM_NOT_FOUND"); return nil; }
        return [self receipt:run];
      }
      // Remember retired operation IDs for this process: eviction never turns
      // an old retry into a second execution. New IDs are bounded too.
      if (self.active || self.operations.count >= 1024 || self.backgrounded) {
        if (error) *error = DSHRuntimeProgramError(@"E_PROGRAM_BUSY"); return nil;
      }
      DSHProgramRun *run = [[DSHProgramRun alloc] init];
      run.runId = NSUUID.UUID.UUIDString.lowercaseString; run.request = immutable;
      run.status = @"starting"; run.stdoutData = [NSMutableData data]; run.stderrData = [NSMutableData data];
      run.vm = self.factory();
      self.active = run; self.runs[run.runId] = run; [self.runOrder addObject:run.runId];
      self.operations[immutable[@"operation_id"]] = @{@"request_sha256":digest, @"run_id":run.runId};
      while (self.runOrder.count > 8) {
        [self.runs removeObjectForKey:self.runOrder.firstObject]; [self.runOrder removeObjectAtIndex:0];
      }
      dispatch_async(self.worker, ^{ [self executeRun:run]; });
      return [self receipt:run];
    }
  } @catch (__unused NSException *exception) {
    if (error) *error = DSHRuntimeProgramError(@"E_PROGRAM_NATIVE"); return nil;
  }
}
- (NSDictionary *)statusRequest:(id)request error:(NSError **)error {
  if (!ValidLocator(request)) { if (error) *error = DSHRuntimeProgramError(@"E_PROGRAM_INVALID_REQUEST"); return nil; }
  @synchronized (self) {
    DSHProgramRun *run = self.runs[request[@"run_id"]];
    if (!run) { if (error) *error = DSHRuntimeProgramError(@"E_PROGRAM_NOT_FOUND"); return nil; }
    return [self receipt:run];
  }
}
- (NSDictionary *)stopRequest:(id)request error:(NSError **)error {
  if (!ValidLocator(request)) { if (error) *error = DSHRuntimeProgramError(@"E_PROGRAM_INVALID_REQUEST"); return nil; }
  @synchronized (self) {
    DSHProgramRun *run = self.runs[request[@"run_id"]];
    if (!run) { if (error) *error = DSHRuntimeProgramError(@"E_PROGRAM_NOT_FOUND"); return nil; }
    if (self.active == run) { run.status = @"stopping"; [run.vm cancel]; }
    return [self receipt:run];
  }
}
- (void)cancelForBackground {
  @synchronized (self) {
    self.backgrounded = YES;
    if (self.active) { self.active.status = @"stopping"; [self.active.vm cancel]; }
  }
}
- (void)appendOutput:(NSData *)data channel:(NSString *)channel run:(DSHProgramRun *)run {
  @synchronized (self) {
    if (self.active != run) return;
    BOOL standard = [channel isEqual:@"stdout"];
    NSMutableData *destination = standard ? run.stdoutData : run.stderrData;
    NSUInteger remaining = 262144 - destination.length;
    [destination appendBytes:data.bytes length:MIN(remaining, data.length)];
    if (data.length > remaining) {
      if (standard) run.stdoutTruncated = YES; else run.stderrTruncated = YES;
    }
  }
}
- (void)executeRun:(DSHProgramRun *)run {
  @autoreleasepool {
    NSError *failure = nil;
    NSNumber *exitCode = nil;
    DSHRuntimeEnvironmentLease *lease = nil;
    @try {
      do {
        if (run.vm.cancelled) break;
        DSHRuntimeWorkspaceSnapshot *snapshot = [DSHRuntimeWorkspaceSnapshot
            captureRoot:run.request[@"root"] entryPath:run.request[@"entry_path"] resolver:self.resolver error:&failure];
        if (!snapshot || run.vm.cancelled) break;
        lease = [self.store acquireLeaseForEnvironmentId:run.request[@"environment_id"] error:nil];
        if (!lease) { failure = DSHRuntimeProgramError(@"E_PROGRAM_ENVIRONMENT"); break; }
        if (run.vm.cancelled) break;
        // A copy can be slow. Revalidate after acquiring it; coordinator ownership
        // never spans file cloning, guest boot or program execution.
        BOOL valid = DSHPerformSessionWorkspaceTransaction(^BOOL(NSError **inner) {
          (void)inner; return [self.resolver validateFrozenRoot:snapshot.frozenRoot error:nil];
        }, nil);
        if (!valid) { failure = DSHRuntimeProgramError(@"E_PROGRAM_ROOT_STALE"); break; }
        exitCode = [run.vm executeLease:lease snapshot:snapshot entryPath:run.request[@"entry_path"]
            args:run.request[@"args"] started:^{
          @synchronized (self) { if (![run.status isEqual:@"stopping"]) run.status = @"running"; }
        } output:^(NSString *channel, NSData *data) {
          [self appendOutput:data channel:channel run:run];
        } error:&failure];
      } while (NO);
    } @catch (__unused NSException *exception) {
      failure = DSHRuntimeProgramError(@"E_PROGRAM_NATIVE");
    } @finally {
      // executeLease has already freed the VM before this private disk is removed.
      if (lease) [self.store releaseLease:lease];
      @synchronized (self) {
        if (run.vm.cancelled) run.status = @"cancelled";
        else if (exitCode != nil) { run.status = @"completed"; run.exitCode = exitCode; }
        else {
          run.status = @"failed";
          run.errorCode = [failure.domain isEqual:DSHRuntimeProgramErrorDomain]
              ? DSHRuntimeProgramError(failure.userInfo[@"code"]).userInfo[@"code"] : @"E_PROGRAM_NATIVE";
        }
        run.vm = nil;
        if (self.active == run) self.active = nil;
      }
    }
  }
}
@end
