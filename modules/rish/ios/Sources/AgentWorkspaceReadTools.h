// Internal descriptor-based workspace observations and shared-core transport.
#import "AgentWorkspaceToolExecutor.h"
#include <dirent.h>
#include <sys/stat.h>

NSString *DSHAgentWorkspacePlainSHA256(NSData *data);
NSDictionary *DSHAgentWorkspaceReduce(NSString *op, NSDictionary *fields, NSError **error);
NSUInteger DSHAgentWorkspaceBound(NSString *name, NSUInteger fallback);
NSArray<NSString *> *DSHAgentWorkspacePathComponents(id value, BOOL allowRoot);
int DSHAgentWorkspaceOpenDirectory(int rootDescriptor, NSArray<NSString *> *components);
int DSHAgentWorkspaceOpenParent(int rootDescriptor, NSArray<NSString *> *components, NSString **name);
NSString *DSHAgentWorkspaceRevision(struct stat metadata);
NSString *DSHAgentWorkspaceFeedback(NSDictionary *feedback, NSError **error);

@interface DSHAgentWorkspaceToolExecutor (DirectoryObservations)
- (BOOL)entryListForDirectoryDescriptor:(int)directoryDescriptor
                               entries:(NSArray **)entriesOut
                           fingerprint:(NSString **)fingerprintOut
                                 error:(NSError **)error;
// Capability seams also allow deterministic directory-race regression tests.
- (struct dirent *)nextEntryInDirectory:(DIR *)directory;
- (int)statEntryNamed:(const char *)name
           directory:(int)descriptor
            metadata:(struct stat *)metadata;
@end
