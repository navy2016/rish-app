#import <Foundation/Foundation.h>
@class DSHAgentRootResolver;

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSErrorDomain const DSHRuntimeProgramErrorDomain;
FOUNDATION_EXPORT NSError *DSHRuntimeProgramError(NSString *code);
FOUNDATION_EXPORT BOOL DSHRuntimeProgramValidRoot(id root);
FOUNDATION_EXPORT BOOL DSHRuntimeProgramValidPath(id path);
/// Looser than DSHEnvironmentValidId on purpose; see the core's
/// runtime_environment::valid_program_environment_id.
FOUNDATION_EXPORT BOOL DSHRuntimeProgramValidEnvironmentId(id value);

/// Native-only detached file bytes. Never serialize these through the bridge.
@interface DSHRuntimeWorkspaceSnapshot : NSObject
@property(nonatomic, copy, readonly) NSDictionary *frozenRoot;
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *entries;
@property(nonatomic, readonly) NSUInteger totalBytes;
+ (nullable instancetype)captureRoot:(NSDictionary *)rootRef
                          entryPath:(NSString *)entryPath
                           resolver:(DSHAgentRootResolver *)resolver
                              error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
