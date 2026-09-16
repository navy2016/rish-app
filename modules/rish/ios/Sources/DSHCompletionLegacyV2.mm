#import "DSHCompletionV2.h"

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
