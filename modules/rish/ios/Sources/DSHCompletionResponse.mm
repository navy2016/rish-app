#import "DSHCompletionV2.h"
#import "RishHarnessCatalog.h"

#include "rish_agent_core.h"
#include <string.h>

static NSDictionary *DSHResponseFailure(NSError **error, NSString *code) {
  if (error != nil) *error = [NSError errorWithDomain:@"DSHCompletionSchema2"
      code:2200 userInfo:@{NSLocalizedDescriptionKey: code}];
  return nil;
}

// Capture NSNumber's original representation before JSON re-encoding can turn
// a provider's 0.0 or 0e0 into 0. Range and position checks belong to the core.
static NSString *DSHResponseIndexStorage(id value) {
  if (value == nil) return @"missing";
  if (![value isKindOfClass:NSNumber.class]) return @"other";
  if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
    return @"boolean";
  }
  const char *type = [(NSNumber *)value objCType];
  if (type == nullptr || type[0] == '\0' || type[1] != '\0') return @"other";
  if (strchr("CSILQ", type[0]) != nullptr) return @"unsigned";
  if (strchr("csilq", type[0]) != nullptr) return @"signed";
  if (strchr("fd", type[0]) != nullptr) return @"floating";
  return @"other";
}

static NSArray *DSHResponseIndexFacts(NSDictionary *decoded) {
  NSArray *choices = [decoded[@"choices"] isKindOfClass:NSArray.class]
      ? decoded[@"choices"] : nil;
  NSDictionary *choice = choices.count == 1 &&
      [choices[0] isKindOfClass:NSDictionary.class] ? choices[0] : nil;
  NSDictionary *message = [choice[@"message"] isKindOfClass:NSDictionary.class]
      ? choice[@"message"] : nil;
  NSArray *calls = [message[@"tool_calls"] isKindOfClass:NSArray.class]
      ? message[@"tool_calls"] : nil;
  NSMutableArray *storage = [NSMutableArray array];
  // The core rejects more than sixteen calls. Do not expand an unbounded host
  // facts array before it can inspect that response.
  for (NSUInteger index = 0; index < MIN(calls.count, 17U); index++) {
    NSDictionary *call = [calls[index] isKindOfClass:NSDictionary.class]
        ? calls[index] : nil;
    [storage addObject:DSHResponseIndexStorage(call[@"index"])];
  }
  return storage;
}

static NSDictionary *DSHResponseReduce(NSDictionary *envelope) {
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:nil];
  // The bounded response plus at most 32 parse/writer facts fit this limit.
  if (bytes == nil || bytes.length > 8 * 1024 * 1024) return nil;
  char *raw = rish_agent_completion_response_reduce(
      (const char *)bytes.bytes, bytes.length);
  if (raw == nullptr) return nil;
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0 error:nil];
  return [reply isKindOfClass:NSDictionary.class] ? reply : nil;
}

// Only perform the mechanical JSON operations requested by the shared parser.
// Reparse the original string so Foundation retains its old number spelling,
// key ordering and escaped slashes. No eligibility or byte-cap policy is here.
static id DSHResponseJSONFact(NSDictionary *request) {
  NSString *source = request[@"source"];
  NSData *bytes = [source dataUsingEncoding:NSUTF8StringEncoding];
  id value = bytes == nil ? nil : [NSJSONSerialization
      JSONObjectWithData:bytes options:0 error:nil];
  if ([request[@"op"] isEqual:@"decode"]) return value ?: NSNull.null;
  NSString *path = request[@"path"];
  if (path.length != 0) {
    value = [value isKindOfClass:NSDictionary.class] ? value[path] : nil;
  }
  if ([request[@"insert_null_revision"] isEqual:@YES]) {
    if (![value isKindOfClass:NSDictionary.class]) return NSNull.null;
    NSMutableDictionary *updated = [value mutableCopy];
    updated[@"expected_revision"] = NSNull.null;
    value = updated;
  }
  NSData *encoded = value == nil ? nil : [NSJSONSerialization
      dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
  return encoded == nil ? NSNull.null :
      ([[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding] ?: NSNull.null);
}

NSDictionary<NSString *, id> *DSHParseCompletionResponseSchema2(
    NSDictionary *decoded, NSString *requestedModel, NSString *thinkingMode,
    NSError **error) {
  if (error != nil) *error = nil;
  if (![decoded isKindOfClass:NSDictionary.class]) {
    return DSHResponseFailure(error, @"E_COMPLETION_RESPONSE_JSON");
  }
  NSString *model = [decoded[@"model"] isKindOfClass:NSString.class] ? decoded[@"model"] : nil;
  NSMutableArray *results = [NSMutableArray array];
  NSMutableDictionary *envelope = [@{
    @"op": @"parse", @"response": decoded,
    @"requested_model": requestedModel ?: @"",
    @"model_supported": @(model != nil && DSHHarnessIsSupportedModel(model)),
    @"thinking_mode": thinkingMode ?: @"",
    @"fallback_call_id": NSUUID.UUID.UUIDString.lowercaseString,
    @"projection_contract": @"foundation-json-v1",
    @"call_index_storage": DSHResponseIndexFacts(decoded),
    @"json_results": results,
  } mutableCopy];
  // Decode facts, requested writer facts, final policy result: at most three
  // core calls, with at most two operations per provider tool call.
  for (NSUInteger phase = 0; phase < 3; phase++) {
    NSDictionary *reply = DSHResponseReduce(envelope);
    if (reply == nil) break;
    if (![reply[@"ok"] isEqual:@YES]) {
      NSString *code = [reply[@"failure_code"] isKindOfClass:NSString.class]
          ? reply[@"failure_code"] : @"E_COMPLETION_RESPONSE_JSON";
      return DSHResponseFailure(error, code);
    }
    NSArray *requests = [reply[@"json_requests"] isKindOfClass:NSArray.class]
        ? reply[@"json_requests"] : nil;
    if (requests == nil) {
      id parsed = reply[@"parsed"];
      if ([parsed isKindOfClass:NSDictionary.class]) return parsed;
      break;
    }
    if (requests.count == 0 || requests.count > 16 || results.count + requests.count > 32) break;
    for (NSDictionary *request in requests) {
      [results addObject:@{@"request": request, @"value": DSHResponseJSONFact(request)}];
    }
  }
  return DSHResponseFailure(error, @"E_COMPLETION_RESPONSE_JSON");
}
