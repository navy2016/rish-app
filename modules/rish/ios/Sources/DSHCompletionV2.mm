#import "DSHCompletionV2.h"
#import "RishHarnessCatalog.h"

#include "rish_agent_core.h"

#include <math.h>
#include <string.h>

NSString * const DSHCompletionV2ErrorDomain = @"DSHCompletionV2Error";

const NSInteger kDSHCompletionEnvelopeVersion = 1;
const NSInteger kDSHCompletionEnvelopeVersion2 = 2;
const NSInteger kDSHCompletionEnvelopeVersion3 = 3;
const NSInteger DSHCompletionV2MaxToolCount = 32;
const NSInteger DSHCompletionV2MaxToolNameLength = 64;
const NSInteger DSHCompletionV2MaxToolDescriptionLength = 1024;
const NSInteger DSHCompletionV2MaxToolSchemaBytes = 6144;
const NSInteger DSHCompletionV2MaxArgumentsBytes = 32768;
const NSInteger DSHCompletionV2MaxToolCalls = 16;

static NSError *DSHCompletionV2Error(NSInteger code, NSString *message) {
  return [NSError errorWithDomain:DSHCompletionV2ErrorDomain
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *DSHV2String(id value) {
  if ([value isKindOfClass:NSString.class]) return value;
  return nil;
}

static BOOL DSHV2ValidToolName(NSString *name) {
  if (name.length == 0 ||
      name.length > (NSUInteger)DSHCompletionV2MaxToolNameLength) {
    return NO;
  }
  static NSCharacterSet *allowed = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"];
  });
  return [[name stringByTrimmingCharactersInSet:allowed] length] == 0;
}

static NSData *_Nullable DSHV2JSONData(id value, NSError **error) {
  NSData *data = value == nil ? nil : [NSJSONSerialization
    dataWithJSONObject:value options:0 error:error];
  return data;
}

static NSError *DSHSchema2Error(NSString *code) {
  return [NSError errorWithDomain:@"DSHCompletionSchema2"
                             code:2200
                         userInfo:@{NSLocalizedDescriptionKey: code}];
}

static BOOL DSHSchema2Fail(NSError **error, NSString *code) {
  if (error != nil) *error = DSHSchema2Error(code);
  return NO;
}

static BOOL DSHSchema2ExactKeys(NSDictionary *value, NSArray<NSString *> *keys) {
  if (![value isKindOfClass:NSDictionary.class]) return NO;
  return [[NSSet setWithArray:value.allKeys]
      isEqualToSet:[NSSet setWithArray:keys]];
}

static BOOL DSHSchema2ExactKeysWithOptional(NSDictionary *value,
                                            NSArray<NSString *> *keys,
                                            NSArray<NSString *> *optional) {
  if (![value isKindOfClass:NSDictionary.class]) return NO;
  NSSet *allowed = [NSSet setWithArray:[keys arrayByAddingObjectsFromArray:optional]];
  NSSet *required = [NSSet setWithArray:keys];
  NSSet *actual = [NSSet setWithArray:value.allKeys];
  return [required isSubsetOfSet:actual] && [actual isSubsetOfSet:allowed];
}

static BOOL DSHSchema2SupportedHarness(NSString *harness) {
  return DSHHarnessIsSupportedHarnessId(harness);
}

static NSString *_Nullable DSHSchema2CanonicalUUID(id value) {
  NSString *candidate = DSHV2String(value);
  if (candidate.length != 36 ||
      ![candidate isEqualToString:candidate.lowercaseString]) {
    return nil;
  }
  NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:candidate];
  NSString *canonical = uuid.UUIDString.lowercaseString;
  return [canonical isEqualToString:candidate] ? canonical : nil;
}

static BOOL DSHSchema2Integer(id value, NSInteger minimum, NSInteger maximum,
                              NSInteger *output) {
  if (![value isKindOfClass:NSNumber.class] ||
      CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
    return NO;
  }
  NSNumber *number = value;
  const char *type = number.objCType;
  if (type == nullptr || type[0] == '\0' || type[1] != '\0') return NO;
  BOOL unsignedStorage = strchr("CSILQ", type[0]) != nullptr;
  BOOL signedStorage = strchr("csilq", type[0]) != nullptr;
  if (!unsignedStorage && !signedStorage) return NO;
  NSInteger integer = 0;
  if (unsignedStorage) {
    unsigned long long raw = number.unsignedLongLongValue;
    if (minimum < 0 || raw > (unsigned long long)maximum) return NO;
    integer = (NSInteger)raw;
  } else {
    long long raw = number.longLongValue;
    if (raw < (long long)minimum || raw > (long long)maximum) return NO;
    integer = (NSInteger)raw;
  }
  if (integer < minimum || integer > maximum) {
    return NO;
  }
  if (output != nil) *output = integer;
  return YES;
}

static BOOL DSHSchema2JSONTreeWithinBudget(
    id value,
    NSUInteger depth,
    NSUInteger *nodeCount,
    NSMutableSet<NSValue *> *ancestors) {
  if (depth > 64 || *nodeCount >= 1024) return NO;
  *nodeCount += 1;
  if (value == NSNull.null || [value isKindOfClass:NSString.class]) {
    if ([value isKindOfClass:NSString.class]) {
      return [value dataUsingEncoding:NSUTF8StringEncoding] != nil;
    }
    return YES;
  }
  if ([value isKindOfClass:NSNumber.class]) {
    if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
      return YES;
    }
    return isfinite(((NSNumber *)value).doubleValue);
  }
  BOOL array = [value isKindOfClass:NSArray.class];
  BOOL dictionary = [value isKindOfClass:NSDictionary.class];
  if (!array && !dictionary) return NO;
  NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)value];
  if ([ancestors containsObject:identity]) return NO;
  [ancestors addObject:identity];
  BOOL valid = YES;
  if (array) {
    for (id child in (NSArray *)value) {
      if (!DSHSchema2JSONTreeWithinBudget(
              child, depth + 1, nodeCount, ancestors)) {
        valid = NO;
        break;
      }
    }
  } else {
    for (id key in (NSDictionary *)value) {
      if (![key isKindOfClass:NSString.class] ||
          [key dataUsingEncoding:NSUTF8StringEncoding] == nil ||
          !DSHSchema2JSONTreeWithinBudget(
              ((NSDictionary *)value)[key], depth + 1,
              nodeCount, ancestors)) {
        valid = NO;
        break;
      }
    }
  }
  [ancestors removeObject:identity];
  return valid;
}

static BOOL DSHSchema2BoundedUTF8String(id value, NSUInteger maximumBytes,
                                        NSString **output) {
  NSString *string = DSHV2String(value);
  NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
  if (string == nil || data == nil || data.length > maximumBytes) return NO;
  if (output != nil) *output = string;
  return YES;
}

static BOOL DSHSchema2OpaqueIdentifier(id value) {
  NSString *string = nil;
  if (!DSHSchema2BoundedUTF8String(value, 128, &string) || string.length == 0) {
    return NO;
  }
  static NSCharacterSet *invalid = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    invalid = [[NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-"]
        invertedSet];
  });
  return [string rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

static NSDictionary *DSHSchema2NormalizeCreateOnlyWriteParameters(
    NSString *name, NSDictionary *parameters) {
  // Only omission defaults to create-only. An explicit value, including a
  // placeholder string, must survive parsing for tool-preparation feedback;
  // coercing it to null would change a malformed update into a create request.
  NSString *path = nil;
  NSString *content = nil;
  if (![name isEqualToString:@"write_file"] ||
      !DSHSchema2ExactKeys(parameters, @[@"path", @"content"]) ||
      !DSHSchema2BoundedUTF8String(parameters[@"path"], 512, &path) ||
      !DSHSchema2BoundedUTF8String(parameters[@"content"],
                                   DSHCompletionV2MaxArgumentsBytes,
                                   &content)) {
    return parameters;
  }
  NSMutableDictionary *createOnly = [parameters mutableCopy];
  createOnly[@"expected_revision"] = NSNull.null;
  return [createOnly copy];
}

static BOOL DSHSchema2SupportedModel(NSString *model) {
  return DSHHarnessIsSupportedModel(model);
}

static BOOL DSHSchema2ThinkingMode(NSString *mode) {
  return [mode isEqualToString:@"off"] || [mode isEqualToString:@"high"] ||
      [mode isEqualToString:@"max"];
}

static NSDictionary *_Nullable DSHSchema2AttachmentReference(
    id raw, NSError **error) {
  NSDictionary *reference = [raw isKindOfClass:NSDictionary.class] ? raw : nil;
  NSArray *keys = @[
    @"schema_version", @"id", @"kind", @"name", @"mime_type", @"size",
  ];
  NSInteger schema = 0;
  NSInteger size = 0;
  NSString *kind = DSHV2String(reference[@"kind"]);
  NSString *name = nil;
  NSString *mimeType = nil;
  BOOL valid = DSHSchema2ExactKeys(reference, keys) &&
      DSHSchema2Integer(reference[@"schema_version"], 1, 1, &schema) &&
      DSHSchema2CanonicalUUID(reference[@"id"]) != nil &&
      ([kind isEqualToString:@"image"] || [kind isEqualToString:@"text"] ||
       [kind isEqualToString:@"pdf"]) &&
      DSHSchema2BoundedUTF8String(reference[@"name"], 512, &name) &&
      name.length > 0 &&
      DSHSchema2BoundedUTF8String(reference[@"mime_type"], 128, &mimeType) &&
      mimeType.length > 0 &&
      DSHSchema2Integer(reference[@"size"], 1, 24 * 1024 * 1024, &size);
  if (!valid) {
    DSHSchema2Fail(error, @"E_COMPLETION_HISTORY");
    return nil;
  }
  return [reference copy];
}

static NSArray *_Nullable DSHSchema2VisibleHistory(id raw, NSError **error) {
  NSArray *history = [raw isKindOfClass:NSArray.class] ? raw : nil;
  if (history.count == 0 || history.count > 200) {
    DSHSchema2Fail(error, @"E_COMPLETION_HISTORY");
    return nil;
  }
  NSUInteger totalBytes = 0;
  NSMutableArray *validated = [NSMutableArray arrayWithCapacity:history.count];
  for (id rawMessage in history) {
    NSDictionary *message = [rawMessage isKindOfClass:NSDictionary.class]
        ? rawMessage : nil;
    NSArray *keys = @[@"role", @"content", @"attachments"];
    NSString *role = DSHV2String(message[@"role"]);
    NSString *content = nil;
    NSArray *attachments = [message[@"attachments"] isKindOfClass:NSArray.class]
        ? message[@"attachments"] : nil;
    BOOL assistant = [role isEqualToString:@"assistant"];
    BOOL roleValid = assistant || [role isEqualToString:@"user"];
    if (!DSHSchema2ExactKeys(message, keys) || !roleValid ||
        !DSHSchema2BoundedUTF8String(message[@"content"], 256 * 1024,
                                     &content) ||
        attachments == nil || attachments.count > 6 ||
        (assistant && attachments.count > 0)) {
      DSHSchema2Fail(error, @"E_COMPLETION_HISTORY");
      return nil;
    }
    NSUInteger contentBytes =
        [content lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (contentBytes > 2 * 1024 * 1024 - totalBytes) {
      DSHSchema2Fail(error, @"E_COMPLETION_HISTORY");
      return nil;
    }
    totalBytes += contentBytes;
    NSMutableArray *validatedAttachments =
        [NSMutableArray arrayWithCapacity:attachments.count];
    NSMutableSet *identifiers = [NSMutableSet set];
    for (id attachment in attachments) {
      NSDictionary *reference = DSHSchema2AttachmentReference(attachment, error);
      NSString *identifier = DSHV2String(reference[@"id"]);
      if (reference == nil || [identifiers containsObject:identifier]) {
        if (reference != nil) DSHSchema2Fail(error, @"E_COMPLETION_HISTORY");
        return nil;
      }
      [identifiers addObject:identifier];
      [validatedAttachments addObject:reference];
    }
    NSString *trimmed = [content stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0 && (! [role isEqualToString:@"user"] ||
                                validatedAttachments.count == 0)) {
      DSHSchema2Fail(error, @"E_COMPLETION_HISTORY");
      return nil;
    }
    [validated addObject:@{
      @"role": role,
      @"content": content,
      @"attachments": validatedAttachments,
    }];
  }
  if (![DSHV2String([validated.lastObject objectForKey:@"role"])
      isEqualToString:@"user"]) {
    DSHSchema2Fail(error, @"E_COMPLETION_HISTORY");
    return nil;
  }
  return validated;
}

NSArray<NSDictionary<NSString *, id> *> * _Nullable DSHCompletionToolsV2FromArray(
    NSArray *tools, NSError **error) {
  if (error != nil) *error = nil;
  if (tools == nil) return @[];
  if (![tools isKindOfClass:NSArray.class]) {
    if (error != nil) {
      *error = DSHCompletionV2Error(2001, @"Tools must be an array");
    }
    return nil;
  }
  if ((NSInteger)tools.count > DSHCompletionV2MaxToolCount) {
    if (error != nil) {
      *error = DSHCompletionV2Error(
        2002, @"Too many tool definitions for one request");
    }
    return nil;
  }
  NSMutableArray<NSDictionary<NSString *, id> *> *sanitized =
    [NSMutableArray arrayWithCapacity:tools.count];
  for (id raw in tools) {
    if (![raw isKindOfClass:NSDictionary.class]) {
      if (error != nil) {
        *error = DSHCompletionV2Error(
          2003, @"Each tool definition must be an object");
      }
      return nil;
    }
    NSDictionary *tool = raw;
    NSString *type = DSHV2String(tool[@"type"]) ?: @"function";
    if (![type isEqualToString:@"function"]) {
      if (error != nil) {
        *error = DSHCompletionV2Error(
          2004, @"Only function tools are supported");
      }
      return nil;
    }
    NSString *name = DSHV2String(tool[@"name"]);
    if (!DSHV2ValidToolName(name)) {
      if (error != nil) {
        *error = DSHCompletionV2Error(
          2005, @"Tool name must use letters, digits, '_' or '-'");
      }
      return nil;
    }
    NSMutableDictionary *function = [NSMutableDictionary dictionary];
    function[@"name"] = name;
    id description = tool[@"description"];
    if (description != nil) {
      NSString *text = DSHV2String(description);
      if (text == nil ||
          text.length > (NSUInteger)DSHCompletionV2MaxToolDescriptionLength) {
        if (error != nil) {
          *error = DSHCompletionV2Error(
            2006, @"Tool description is missing or too long");
        }
        return nil;
      }
      function[@"description"] = text;
    }
    id parameters = tool[@"parameters"];
    if (parameters != nil) {
      if (![parameters isKindOfClass:NSDictionary.class]) {
        if (error != nil) {
          *error = DSHCompletionV2Error(
            2007, @"Tool parameters must be an object");
        }
        return nil;
      }
      NSData *schema = DSHV2JSONData(parameters, error);
      if (schema == nil || (NSInteger)schema.length >
            DSHCompletionV2MaxToolSchemaBytes) {
        if (error != nil && *error == nil) {
          *error = DSHCompletionV2Error(
            2008, @"Tool parameter schema exceeds the size limit");
        }
        return nil;
      }
      function[@"parameters"] = parameters;
    }
    [sanitized addObject:@{
      @"type": @"function",
      @"function": function,
    }];
  }
  return sanitized;
}

NSDictionary<NSString *, id> * DSHCompletionRequestBodyV2(
    NSString *model,
    NSString *thinkingMode,
    NSArray<NSDictionary<NSString *, id> *> *messages,
    NSArray<NSDictionary<NSString *, id> *> *tools) {
  if (model.length == 0 || thinkingMode.length == 0 || messages == nil) {
    return nil;
  }
  NSMutableDictionary *body = [@{
    @"model": model,
    @"stream": @NO,
    @"thinking": @{@"type": [thinkingMode isEqualToString:@"off"]
                        ? @"disabled" : @"enabled"},
    // Tool arguments can contain an entire file. Keep room for that output
    // even when reasoning is disabled, plus reasoning room when enabled.
    @"max_tokens": tools.count > 0
        ? ([thinkingMode isEqualToString:@"off"] ? @8192 : @16384)
        : ([thinkingMode isEqualToString:@"off"] ? @1024 : @4096),
    @"messages": messages,
  } mutableCopy];
  if (![thinkingMode isEqualToString:@"off"]) {
    body[@"reasoning_effort"] = thinkingMode;
  }
  if (tools.count > 0) {
    body[@"tools"] = tools;
  }
  return body;
}

NSDictionary<NSString *, id> * _Nullable DSHParseCompletionResponseV2(
    NSDictionary *decoded, NSError **error) {
  if (error != nil) *error = nil;
  if (![decoded isKindOfClass:NSDictionary.class]) {
    if (error != nil) {
      *error = DSHCompletionV2Error(2101, @"Response root must be an object");
    }
    return nil;
  }
  NSArray *choices = [decoded[@"choices"] isKindOfClass:NSArray.class]
    ? decoded[@"choices"] : nil;
  if (choices.count == 0) {
    if (error != nil) {
      *error = DSHCompletionV2Error(2102, @"Response has no choices");
    }
    return nil;
  }
  NSDictionary *choice = choices.firstObject;
  if (![choice isKindOfClass:NSDictionary.class]) {
    if (error != nil) {
      *error = DSHCompletionV2Error(2103, @"Choice must be an object");
    }
    return nil;
  }
  NSString *finishReason = DSHV2String(choice[@"finish_reason"]);
  if (finishReason.length == 0 || finishReason.length > 128) {
    finishReason = @"unknown";
  }
  NSDictionary *message = choice[@"message"];
  if (![message isKindOfClass:NSDictionary.class]) message = @{};
  NSString *text = DSHV2String(message[@"content"]) ?: @"";
  NSString *reasoning = DSHV2String(message[@"reasoning_content"]) ?: @"";

  NSMutableArray<NSDictionary<NSString *, id> *> *toolCalls =
    [NSMutableArray array];
  id rawCalls = message[@"tool_calls"];
  if (rawCalls != nil) {
    if (![rawCalls isKindOfClass:NSArray.class]) {
      if (error != nil) {
        *error = DSHCompletionV2Error(
          2104, @"tool_calls must be an array when present");
      }
      return nil;
    }
    if ((NSInteger)((NSArray *)rawCalls).count > DSHCompletionV2MaxToolCalls) {
      if (error != nil) {
        *error = DSHCompletionV2Error(
          2105, @"Response carries too many tool calls");
      }
      return nil;
    }
    for (id rawCall in rawCalls) {
      if (![rawCall isKindOfClass:NSDictionary.class]) {
        if (error != nil) {
          *error = DSHCompletionV2Error(
            2106, @"Each tool call must be an object");
        }
        return nil;
      }
      NSDictionary *call = rawCall;
      NSString *identifier = DSHV2String(call[@"id"]);
      if (identifier.length == 0 || identifier.length > 128) {
        if (error != nil) {
          *error = DSHCompletionV2Error(
            2107, @"Tool call is missing a usable id");
        }
        return nil;
      }
      NSDictionary *function = call[@"function"];
      if (![function isKindOfClass:NSDictionary.class]) {
        if (error != nil) {
          *error = DSHCompletionV2Error(
            2108, @"Tool call must carry a function object");
        }
        return nil;
      }
      NSString *name = DSHV2String(function[@"name"]);
      if (name.length == 0 || name.length > 128) {
        if (error != nil) {
          *error = DSHCompletionV2Error(
            2109, @"Tool call is missing a usable function name");
        }
        return nil;
      }
      NSString *arguments = DSHV2String(function[@"arguments"]);
      NSData *argumentBytes =
        [arguments dataUsingEncoding:NSUTF8StringEncoding];
      if (arguments == nil || argumentBytes == nil ||
          (NSInteger)argumentBytes.length > DSHCompletionV2MaxArgumentsBytes) {
        if (error != nil) {
          *error = DSHCompletionV2Error(
            2110, @"Tool call arguments are missing or oversized");
        }
        return nil;
      }
      [toolCalls addObject:@{
        @"id": identifier,
        @"name": name,
        @"arguments": arguments,
      }];
    }
  }

  NSString *trimmed = [text stringByTrimmingCharactersInSet:
    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (trimmed.length == 0 && toolCalls.count == 0) {
    if (error != nil) {
      *error = DSHCompletionV2Error(2111, [NSString stringWithFormat:
        @"Assistant response is empty (finish=%@)", finishReason]);
    }
    return nil;
  }
  return @{
    @"text": text,
    @"reasoning": reasoning,
    @"finish_reason": finishReason,
    @"tool_calls": toolCalls,
  };
}

NSArray<NSDictionary<NSString *, id> *> * _Nullable
DSHCompletionProviderToolsSchema2FromArray(NSArray *tools, NSError **error) {
  if (error != nil) *error = nil;
  if (![tools isKindOfClass:NSArray.class] || tools.count > 32) {
    DSHSchema2Fail(error, @"E_COMPLETION_TOOLS");
    return nil;
  }
  NSMutableArray *validated = [NSMutableArray arrayWithCapacity:tools.count];
  for (id raw in tools) {
    NSDictionary *tool = [raw isKindOfClass:NSDictionary.class] ? raw : nil;
    NSDictionary *function = [tool[@"function"] isKindOfClass:NSDictionary.class]
        ? tool[@"function"] : nil;
    NSString *name = DSHV2String(function[@"name"]);
    NSString *description = DSHV2String(function[@"description"]);
    NSDictionary *parameters =
        [function[@"parameters"] isKindOfClass:NSDictionary.class]
            ? function[@"parameters"] : nil;
    NSUInteger nodeCount = 0;
    BOOL treeWithinBudget = parameters != nil &&
        DSHSchema2JSONTreeWithinBudget(
            parameters, 0, &nodeCount, [NSMutableSet set]);
    NSError *jsonError = nil;
    NSData *schema = treeWithinBudget
        ? DSHV2JSONData(parameters, &jsonError) : nil;
    if (!DSHSchema2ExactKeys(tool, @[@"type", @"function"]) ||
        ![DSHV2String(tool[@"type"]) isEqualToString:@"function"] ||
        !DSHSchema2ExactKeys(function,
                            @[@"name", @"description", @"parameters"]) ||
        !DSHV2ValidToolName(name) || description == nil ||
        description.length > (NSUInteger)DSHCompletionV2MaxToolDescriptionLength ||
        parameters == nil || !treeWithinBudget || schema == nil ||
        jsonError != nil ||
        schema.length > (NSUInteger)DSHCompletionV2MaxToolSchemaBytes) {
      DSHSchema2Fail(error, @"E_COMPLETION_TOOLS");
      return nil;
    }
    [validated addObject:@{
      @"type": @"function",
      @"function": @{
        @"name": name,
        @"description": description,
        @"parameters": parameters,
      },
    }];
  }
  return validated;
}

NSArray<NSDictionary<NSString *, id> *> * _Nullable
DSHCompletionRoundTranscriptSchema2FromArray(
    NSArray *transcript,
    NSInteger roundIndex,
    NSString *thinkingMode,
    NSError **error) {
  if (error != nil) *error = nil;
  if (![transcript isKindOfClass:NSArray.class] || roundIndex < 0 ||
      roundIndex > 7 || !DSHSchema2ThinkingMode(thinkingMode)) {
    DSHSchema2Fail(error, @"E_COMPLETION_TRANSCRIPT");
    return nil;
  }
  NSMutableArray *validated = [NSMutableArray arrayWithCapacity:transcript.count];
  NSMutableSet<NSString *> *allCallIds = [NSMutableSet set];
  NSUInteger totalBytes = 0;
  NSInteger groupCount = 0;
  NSUInteger index = 0;
  while (index < transcript.count) {
    NSDictionary *assistant = [transcript[index] isKindOfClass:NSDictionary.class]
        ? transcript[index] : nil;
    NSString *content = nil;
    NSString *reasoning = nil;
    NSArray *calls = [assistant[@"tool_calls"] isKindOfClass:NSArray.class]
        ? assistant[@"tool_calls"] : nil;
    if (!DSHSchema2ExactKeys(assistant,
            @[@"role", @"content", @"reasoning_content", @"tool_calls"]) ||
        ![DSHV2String(assistant[@"role"]) isEqualToString:@"assistant"] ||
        !DSHSchema2BoundedUTF8String(assistant[@"content"], 256 * 1024,
                                     &content) ||
        !DSHSchema2BoundedUTF8String(assistant[@"reasoning_content"],
                                     256 * 1024, &reasoning) ||
        calls.count == 0 || calls.count > 16) {
      DSHSchema2Fail(error, @"E_COMPLETION_TRANSCRIPT");
      return nil;
    }
    NSUInteger contentBytes =
        [content lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    NSUInteger reasoningBytes =
        [reasoning lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (contentBytes > 4 * 1024 * 1024 - totalBytes) {
      DSHSchema2Fail(error, @"E_COMPLETION_TRANSCRIPT");
      return nil;
    }
    totalBytes += contentBytes;
    if (reasoningBytes > 4 * 1024 * 1024 - totalBytes) {
      DSHSchema2Fail(error, @"E_COMPLETION_TRANSCRIPT");
      return nil;
    }
    totalBytes += reasoningBytes;

    NSMutableArray *validatedCalls = [NSMutableArray arrayWithCapacity:calls.count];
    NSMutableArray<NSString *> *orderedIds = [NSMutableArray arrayWithCapacity:calls.count];
    for (id rawCall in calls) {
      NSDictionary *call = [rawCall isKindOfClass:NSDictionary.class] ? rawCall : nil;
      NSDictionary *function =
          [call[@"function"] isKindOfClass:NSDictionary.class]
              ? call[@"function"] : nil;
      NSString *identifier = DSHV2String(call[@"id"]);
      NSString *name = DSHV2String(function[@"name"]);
      NSString *arguments = nil;
      if (!DSHSchema2ExactKeys(call, @[@"id", @"type", @"function"]) ||
          !DSHSchema2OpaqueIdentifier(identifier) ||
          [allCallIds containsObject:identifier] ||
          ![DSHV2String(call[@"type"]) isEqualToString:@"function"] ||
          !DSHSchema2ExactKeys(function, @[@"name", @"arguments"]) ||
          !DSHV2ValidToolName(name) ||
          !DSHSchema2BoundedUTF8String(
              function[@"arguments"], DSHCompletionV2MaxArgumentsBytes,
              &arguments)) {
        DSHSchema2Fail(error, @"E_COMPLETION_TRANSCRIPT");
        return nil;
      }
      [allCallIds addObject:identifier];
      [orderedIds addObject:identifier];
      [validatedCalls addObject:@{
        @"id": identifier,
        @"type": @"function",
        @"function": @{@"name": name, @"arguments": arguments},
      }];
    }
    [validated addObject:@{
      @"role": @"assistant",
      @"content": content,
      @"reasoning_content": reasoning,
      @"tool_calls": validatedCalls,
    }];
    index += 1;
    for (NSUInteger callIndex = 0; callIndex < calls.count; callIndex += 1) {
      if (index >= transcript.count) {
        DSHSchema2Fail(error, @"E_COMPLETION_TRANSCRIPT");
        return nil;
      }
      NSDictionary *tool = [transcript[index] isKindOfClass:NSDictionary.class]
          ? transcript[index] : nil;
      NSString *toolCallId = DSHV2String(tool[@"tool_call_id"]);
      NSString *toolContent = nil;
      if (!DSHSchema2ExactKeys(tool,
              @[@"role", @"tool_call_id", @"content"]) ||
          ![DSHV2String(tool[@"role"]) isEqualToString:@"tool"] ||
          ![toolCallId isEqualToString:orderedIds[callIndex]] ||
          !DSHSchema2BoundedUTF8String(tool[@"content"], 256 * 1024,
                                       &toolContent)) {
        DSHSchema2Fail(error, @"E_COMPLETION_TRANSCRIPT");
        return nil;
      }
      NSUInteger toolBytes =
          [toolContent lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
      if (toolBytes > 4 * 1024 * 1024 - totalBytes) {
        DSHSchema2Fail(error, @"E_COMPLETION_TRANSCRIPT");
        return nil;
      }
      totalBytes += toolBytes;
      [validated addObject:@{
        @"role": @"tool",
        @"tool_call_id": toolCallId,
        @"content": toolContent,
      }];
      index += 1;
    }
    groupCount += 1;
  }
  if (groupCount != roundIndex || (roundIndex == 0 && validated.count != 0)) {
    DSHSchema2Fail(error, @"E_COMPLETION_TRANSCRIPT");
    return nil;
  }
  return validated;
}

NSDictionary<NSString *, id> * _Nullable
DSHCompletionEnvelopeSchema2FromDictionary(NSDictionary *envelope,
                                            NSError **error) {
  if (error != nil) *error = nil;
  NSArray *keys = @[
    @"schema_version", @"turn_id", @"attempt_id", @"round_id",
    @"round_index", @"model", @"thinking_mode", @"visible_history",
    @"round_transcript", @"tools", @"project_context",
  ];
  NSInteger schemaVersion = 0;
  if (!DSHSchema2ExactKeysWithOptional(envelope, keys, @[@"harness_id"]) ||
      !DSHSchema2Integer(envelope[@"schema_version"], 2, 2,
                         &schemaVersion)) {
    DSHSchema2Fail(error, @"E_COMPLETION_SCHEMA");
    return nil;
  }
  NSString *harnessId = DSHV2String(envelope[@"harness_id"]);
  if (harnessId == nil) {
    harnessId = @"dsh";
  } else if (!DSHSchema2SupportedHarness(harnessId)) {
    DSHSchema2Fail(error, @"E_COMPLETION_MODEL");
    return nil;
  }
  if (envelope[@"project_context"] != NSNull.null) {
    DSHSchema2Fail(error, @"E_COMPLETION_CONTEXT_UNSUPPORTED");
    return nil;
  }
  NSString *turnId = DSHSchema2CanonicalUUID(envelope[@"turn_id"]);
  NSString *attemptId = DSHSchema2CanonicalUUID(envelope[@"attempt_id"]);
  NSString *roundId = DSHSchema2CanonicalUUID(envelope[@"round_id"]);
  if (turnId == nil || attemptId == nil || roundId == nil) {
    DSHSchema2Fail(error, @"E_COMPLETION_IDENTIFIER");
    return nil;
  }
  NSInteger roundIndex = 0;
  if (!DSHSchema2Integer(envelope[@"round_index"], 0, 7, &roundIndex)) {
    DSHSchema2Fail(error, @"E_COMPLETION_ROUND");
    return nil;
  }
  NSString *model = DSHV2String(envelope[@"model"]);
  if (!DSHSchema2SupportedModel(model) ||
      ![DSHHarnessIdForModel(model) isEqualToString:harnessId]) {
    DSHSchema2Fail(error, @"E_COMPLETION_MODEL");
    return nil;
  }
  NSString *thinkingMode = DSHV2String(envelope[@"thinking_mode"]);
  if (!DSHSchema2ThinkingMode(thinkingMode)) {
    DSHSchema2Fail(error, @"E_COMPLETION_THINKING");
    return nil;
  }
  NSArray *visible = DSHSchema2VisibleHistory(envelope[@"visible_history"], error);
  if (visible == nil) return nil;
  NSArray *transcript = DSHCompletionRoundTranscriptSchema2FromArray(
      envelope[@"round_transcript"], roundIndex, thinkingMode, error);
  if (transcript == nil) return nil;
  NSArray *tools = DSHCompletionProviderToolsSchema2FromArray(
      envelope[@"tools"], error);
  if (tools == nil) return nil;
  return @{
    @"schema_version": @2,
    @"harness_id": harnessId,
    @"turn_id": turnId,
    @"attempt_id": attemptId,
    @"round_id": roundId,
    @"round_index": @(roundIndex),
    @"model": model,
    @"thinking_mode": thinkingMode,
    @"visible_history": visible,
    @"round_transcript": transcript,
    @"tools": tools,
    @"project_context": NSNull.null,
  };
}

NSDictionary<NSString *, id> * _Nullable
DSHCompletionEnvelopeSchema3FromDictionary(NSDictionary *envelope,
                                            NSError **error) {
  if (error != nil) *error = nil;
  NSArray *keys = @[
    @"schema_version", @"turn_id", @"attempt_id", @"round_id",
    @"round_index", @"model", @"thinking_mode", @"visible_history",
    @"round_transcript", @"tools", @"project_context",
  ];
  NSInteger schemaVersion = 0;
  if (!DSHSchema2ExactKeysWithOptional(envelope, keys, @[@"harness_id"]) ||
      !DSHSchema2Integer(envelope[@"schema_version"], 3, 3,
                         &schemaVersion)) {
    DSHSchema2Fail(error, @"E_COMPLETION_SCHEMA");
    return nil;
  }
  NSString *harnessId = DSHV2String(envelope[@"harness_id"]);
  if (harnessId == nil) {
    harnessId = @"dsh";
  } else if (!DSHSchema2SupportedHarness(harnessId)) {
    DSHSchema2Fail(error, @"E_COMPLETION_MODEL");
    return nil;
  }
  NSString *turnId = DSHSchema2CanonicalUUID(envelope[@"turn_id"]);
  NSString *attemptId = DSHSchema2CanonicalUUID(envelope[@"attempt_id"]);
  NSString *roundId = DSHSchema2CanonicalUUID(envelope[@"round_id"]);
  if (turnId == nil || attemptId == nil || roundId == nil) {
    DSHSchema2Fail(error, @"E_COMPLETION_IDENTIFIER");
    return nil;
  }
  NSInteger roundIndex = 0;
  if (!DSHSchema2Integer(envelope[@"round_index"], 0, 7, &roundIndex)) {
    DSHSchema2Fail(error, @"E_COMPLETION_ROUND");
    return nil;
  }
  NSString *model = DSHV2String(envelope[@"model"]);
  if (!DSHSchema2SupportedModel(model) ||
      ![DSHHarnessIdForModel(model) isEqualToString:harnessId]) {
    DSHSchema2Fail(error, @"E_COMPLETION_MODEL");
    return nil;
  }
  NSString *thinkingMode = DSHV2String(envelope[@"thinking_mode"]);
  if (!DSHSchema2ThinkingMode(thinkingMode)) {
    DSHSchema2Fail(error, @"E_COMPLETION_THINKING");
    return nil;
  }
  NSDictionary *rawContext =
      [envelope[@"project_context"] isKindOfClass:NSDictionary.class]
          ? envelope[@"project_context"] : nil;
  NSArray *contextKeys = @[
    @"schema_version", @"snapshot_id", @"consent_receipt_id",
    @"conversation_id", @"project_id", @"provider", @"policy",
  ];
  NSInteger contextSchema = 0;
  NSString *snapshotId = DSHSchema2CanonicalUUID(rawContext[@"snapshot_id"]);
  NSString *consentReceiptId =
      DSHSchema2CanonicalUUID(rawContext[@"consent_receipt_id"]);
  NSString *conversationId =
      DSHSchema2CanonicalUUID(rawContext[@"conversation_id"]);
  NSString *projectId = DSHSchema2CanonicalUUID(rawContext[@"project_id"]);
  if (!DSHSchema2ExactKeys(rawContext, contextKeys) ||
      !DSHSchema2Integer(rawContext[@"schema_version"], 1, 1,
                         &contextSchema) ||
      snapshotId == nil || consentReceiptId == nil ||
      conversationId == nil || projectId == nil ||
      ![DSHV2String(rawContext[@"provider"])
          isEqualToString:DSHProviderIdForModel(model)] ||
      ![DSHV2String(rawContext[@"policy"])
          isEqualToString:@"chat-read-v1"]) {
    DSHSchema2Fail(error, @"E_COMPLETION_CONTEXT_INVALID");
    return nil;
  }
  NSArray *visible = DSHSchema2VisibleHistory(envelope[@"visible_history"], error);
  if (visible == nil) return nil;
  NSArray *transcript = DSHCompletionRoundTranscriptSchema2FromArray(
      envelope[@"round_transcript"], roundIndex, thinkingMode, error);
  if (transcript == nil) return nil;
  NSArray *tools = DSHCompletionProviderToolsSchema2FromArray(
      envelope[@"tools"], error);
  if (tools == nil) return nil;
  return @{
    @"schema_version": @3,
    @"harness_id": harnessId,
    @"turn_id": turnId,
    @"attempt_id": attemptId,
    @"round_id": roundId,
    @"round_index": @(roundIndex),
    @"model": model,
    @"thinking_mode": thinkingMode,
    @"visible_history": visible,
    @"round_transcript": transcript,
    @"tools": tools,
    @"project_context": @{
      @"schema_version": @1,
      @"snapshot_id": snapshotId,
      @"consent_receipt_id": consentReceiptId,
      @"conversation_id": conversationId,
      @"project_id": projectId,
      @"provider": DSHProviderIdForModel(model),
      @"policy": @"chat-read-v1",
    },
  };
}

// Turning a provider's reply into tool calls the engine will run lives in the
// shared core (modules/rish/core, `rish_agent_completion_response_reduce`).
// This is the boundary where untrusted model output becomes something
// executable — a call that gets through it is a call a person will be asked to
// approve — so there is one copy of the rule, and it is not this one.  What
// stays here are the two facts only the host has: whether a model is in this
// build's catalogue, and a fresh identifier for the compatibility path.
NSDictionary<NSString *, id> *_Nullable
DSHParseCompletionResponseSchema2(
    NSDictionary *decoded,
    NSString *requestedModel,
    NSString *thinkingMode,
    NSError **error) {
  if (error != nil) *error = nil;
  if (![decoded isKindOfClass:NSDictionary.class]) {
    DSHSchema2Fail(error, @"E_COMPLETION_RESPONSE_JSON");
    return nil;
  }
  NSString *model = DSHV2String(decoded[@"model"]);
  NSDictionary *envelope = @{
    @"op" : @"parse",
    @"response" : decoded,
    @"requested_model" : requestedModel ?: @"",
    @"model_supported" : @(model != nil && DSHSchema2SupportedModel(model)),
    @"thinking_mode" : thinkingMode ?: @"",
    @"fallback_call_id" : NSUUID.UUID.UUIDString.lowercaseString,
  };
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:envelope options:0
                                                    error:nil];
  char *raw = bytes == nil ? NULL : rish_agent_completion_response_reduce(
      (const char *)bytes.bytes, bytes.length);
  if (raw == NULL) {
    DSHSchema2Fail(error, @"E_COMPLETION_RESPONSE_JSON");
    return nil;
  }
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0
                                                error:nil];
  if (![reply isKindOfClass:NSDictionary.class]) {
    DSHSchema2Fail(error, @"E_COMPLETION_RESPONSE_JSON");
    return nil;
  }
  if (![reply[@"ok"] isEqual:@YES]) {
    NSString *code = [reply[@"failure_code"] isKindOfClass:NSString.class]
        ? reply[@"failure_code"] : @"E_COMPLETION_RESPONSE_JSON";
    DSHSchema2Fail(error, code);
    return nil;
  }
  id parsed = reply[@"parsed"];
  if (![parsed isKindOfClass:NSDictionary.class]) {
    DSHSchema2Fail(error, @"E_COMPLETION_RESPONSE_JSON");
    return nil;
  }
  return parsed;
}

NSArray<NSDictionary<NSString *, id> *> *DSHCompletionNormalizeToolCalls(
    NSArray<NSDictionary<NSString *, id> *> *toolCalls) {
  if (![toolCalls isKindOfClass:NSArray.class]) return @[];
  NSMutableArray *normalizedCalls = [NSMutableArray arrayWithCapacity:toolCalls.count];
  for (id rawCall in toolCalls) {
    NSDictionary *call = [rawCall isKindOfClass:NSDictionary.class] ? rawCall : nil;
    NSString *name = DSHV2String(call[@"name"]);
    NSString *arguments = DSHV2String(call[@"arguments"]);
    if (call == nil || ![name isEqualToString:@"write_file"] || arguments == nil) {
      if (call != nil) [normalizedCalls addObject:call];
      continue;
    }
    NSData *argumentBytes = [arguments dataUsingEncoding:NSUTF8StringEncoding];
    id value = argumentBytes == nil ? nil :
        [NSJSONSerialization JSONObjectWithData:argumentBytes options:0 error:nil];
    NSDictionary *parameters = [value isKindOfClass:NSDictionary.class] ? value : nil;
    NSDictionary *normalized = parameters == nil ? nil :
        DSHSchema2NormalizeCreateOnlyWriteParameters(name, parameters);
    if (normalized == nil || normalized == parameters) {
      [normalizedCalls addObject:call];
      continue;
    }
    NSData *normalizedBytes = [NSJSONSerialization
        dataWithJSONObject:normalized options:NSJSONWritingSortedKeys error:nil];
    NSString *normalizedArguments = normalizedBytes == nil ? nil :
        [[NSString alloc] initWithData:normalizedBytes encoding:NSUTF8StringEncoding];
    if (normalizedArguments == nil ||
        normalizedBytes.length > (NSUInteger)DSHCompletionV2MaxArgumentsBytes) {
      [normalizedCalls addObject:call];
      continue;
    }
    NSMutableDictionary *updated = [call mutableCopy];
    updated[@"arguments"] = normalizedArguments;
    [normalizedCalls addObject:[updated copy]];
  }
  return [normalizedCalls copy];
}
