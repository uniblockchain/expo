/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "ABI21_0_0RCTModuleMethod.h"

#import <objc/message.h>

#import "ABI21_0_0RCTAssert.h"
#import "ABI21_0_0RCTBridge+Private.h"
#import "ABI21_0_0RCTBridge.h"
#import "ABI21_0_0RCTConvert.h"
#import "ABI21_0_0RCTLog.h"
#import "ABI21_0_0RCTParserUtils.h"
#import "ABI21_0_0RCTProfile.h"
#import "ABI21_0_0RCTUtils.h"

typedef BOOL (^ABI21_0_0RCTArgumentBlock)(ABI21_0_0RCTBridge *, NSUInteger, id);

@implementation ABI21_0_0RCTMethodArgument

- (instancetype)initWithType:(NSString *)type
                 nullability:(ABI21_0_0RCTNullability)nullability
                      unused:(BOOL)unused
{
  if (self = [super init]) {
    _type = [type copy];
    _nullability = nullability;
    _unused = unused;
  }
  return self;
}

@end

@implementation ABI21_0_0RCTModuleMethod
{
  Class _moduleClass;
  const ABI21_0_0RCTMethodInfo *_methodInfo;
  NSString *_JSMethodName;

  SEL _selector;
  NSInvocation *_invocation;
  NSArray<ABI21_0_0RCTArgumentBlock> *_argumentBlocks;
}

static void ABI21_0_0RCTLogArgumentError(ABI21_0_0RCTModuleMethod *method, NSUInteger index,
                                id valueOrType, const char *issue)
{
  ABI21_0_0RCTLogError(@"Argument %tu (%@) of %@.%s %s", index, valueOrType,
              ABI21_0_0RCTBridgeModuleNameForClass(method->_moduleClass),
              method.JSMethodName, issue);
}

ABI21_0_0RCT_NOT_IMPLEMENTED(- (instancetype)init)

// returns YES if the selector ends in a colon (indicating that there is at
// least one argument, and maybe more selector parts) or NO if it doesn't.
static BOOL ABI21_0_0RCTParseSelectorPart(const char **input, NSMutableString *selector)
{
  NSString *selectorPart;
  if (ABI21_0_0RCTParseIdentifier(input, &selectorPart)) {
    [selector appendString:selectorPart];
  }
  ABI21_0_0RCTSkipWhitespace(input);
  if (ABI21_0_0RCTReadChar(input, ':')) {
    [selector appendString:@":"];
    ABI21_0_0RCTSkipWhitespace(input);
    return YES;
  }
  return NO;
}

static BOOL ABI21_0_0RCTParseUnused(const char **input)
{
  return ABI21_0_0RCTReadString(input, "__unused") ||
         ABI21_0_0RCTReadString(input, "__attribute__((unused))");
}

static ABI21_0_0RCTNullability ABI21_0_0RCTParseNullability(const char **input)
{
  if (ABI21_0_0RCTReadString(input, "nullable")) {
    return ABI21_0_0RCTNullable;
  } else if (ABI21_0_0RCTReadString(input, "nonnull")) {
    return ABI21_0_0RCTNonnullable;
  }
  return ABI21_0_0RCTNullabilityUnspecified;
}

static ABI21_0_0RCTNullability ABI21_0_0RCTParseNullabilityPostfix(const char **input)
{
  if (ABI21_0_0RCTReadString(input, "_Nullable")) {
    return ABI21_0_0RCTNullable;
  } else if (ABI21_0_0RCTReadString(input, "_Nonnull")) {
    return ABI21_0_0RCTNonnullable;
  }
  return ABI21_0_0RCTNullabilityUnspecified;
}

// returns YES if execution is safe to proceed (enqueue callback invocation), NO if callback has already been invoked
#if ABI21_0_0RCT_DEBUG
static BOOL checkCallbackMultipleInvocations(BOOL *didInvoke) {
  if (*didInvoke) {
      ABI21_0_0RCTFatal(ABI21_0_0RCTErrorWithMessage(@"Illegal callback invocation from native module. This callback type only permits a single invocation from native code."));
      return NO;
  } else {
      *didInvoke = YES;
      return YES;
  }
}
#endif

SEL ABI21_0_0RCTParseMethodSignature(const char *, NSArray<ABI21_0_0RCTMethodArgument *> **);
SEL ABI21_0_0RCTParseMethodSignature(const char *input, NSArray<ABI21_0_0RCTMethodArgument *> **arguments)
{
  ABI21_0_0RCTSkipWhitespace(&input);

  NSMutableArray *args;
  NSMutableString *selector = [NSMutableString new];
  while (ABI21_0_0RCTParseSelectorPart(&input, selector)) {
    if (!args) {
      args = [NSMutableArray new];
    }

    // Parse type
    if (ABI21_0_0RCTReadChar(&input, '(')) {
      ABI21_0_0RCTSkipWhitespace(&input);

      BOOL unused = ABI21_0_0RCTParseUnused(&input);
      ABI21_0_0RCTSkipWhitespace(&input);

      ABI21_0_0RCTNullability nullability = ABI21_0_0RCTParseNullability(&input);
      ABI21_0_0RCTSkipWhitespace(&input);

      NSString *type = ABI21_0_0RCTParseType(&input);
      ABI21_0_0RCTSkipWhitespace(&input);
      if (nullability == ABI21_0_0RCTNullabilityUnspecified) {
        nullability = ABI21_0_0RCTParseNullabilityPostfix(&input);
      }
      [args addObject:[[ABI21_0_0RCTMethodArgument alloc] initWithType:type
                                                  nullability:nullability
                                                       unused:unused]];
      ABI21_0_0RCTSkipWhitespace(&input);
      ABI21_0_0RCTReadChar(&input, ')');
      ABI21_0_0RCTSkipWhitespace(&input);
    } else {
      // Type defaults to id if unspecified
      [args addObject:[[ABI21_0_0RCTMethodArgument alloc] initWithType:@"id"
                                                  nullability:ABI21_0_0RCTNullable
                                                       unused:NO]];
    }

    // Argument name
    ABI21_0_0RCTParseIdentifier(&input, NULL);
    ABI21_0_0RCTSkipWhitespace(&input);
  }

  *arguments = [args copy];
  return NSSelectorFromString(selector);
}

- (instancetype)initWithExportedMethod:(const ABI21_0_0RCTMethodInfo *)exportedMethod
                           moduleClass:(Class)moduleClass
{
  if (self = [super init]) {
    _moduleClass = moduleClass;
    _methodInfo = exportedMethod;
  }
  return self;
}

- (void)processMethodSignature
{
  NSArray<ABI21_0_0RCTMethodArgument *> *arguments;
  _selector = ABI21_0_0RCTParseMethodSignature(_methodInfo->objcName, &arguments);
  ABI21_0_0RCTAssert(_selector, @"%s is not a valid selector", _methodInfo->objcName);

  // Create method invocation
  NSMethodSignature *methodSignature = [_moduleClass instanceMethodSignatureForSelector:_selector];
  ABI21_0_0RCTAssert(methodSignature, @"%s is not a recognized Objective-C method.", sel_getName(_selector));
  NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:methodSignature];
  invocation.selector = _selector;
  _invocation = invocation;

  // Process arguments
  NSUInteger numberOfArguments = methodSignature.numberOfArguments;
  NSMutableArray<ABI21_0_0RCTArgumentBlock> *argumentBlocks =
    [[NSMutableArray alloc] initWithCapacity:numberOfArguments - 2];

#if ABI21_0_0RCT_DEBUG
  __weak ABI21_0_0RCTModuleMethod *weakSelf = self;
#endif

#define ABI21_0_0RCT_ARG_BLOCK(_logic) \
[argumentBlocks addObject:^(__unused ABI21_0_0RCTBridge *bridge, NSUInteger index, id json) { \
  _logic                                                                             \
  [invocation setArgument:&value atIndex:(index) + 2];                               \
  return YES;                                                                        \
}]

#define __PRIMITIVE_CASE(_type, _nullable) {                                   \
  isNullableType = _nullable;                                                  \
  _type (*convert)(id, SEL, id) = (typeof(convert))objc_msgSend;               \
  ABI21_0_0RCT_ARG_BLOCK( _type value = convert([ABI21_0_0RCTConvert class], selector, json); ); \
  break;                                                                       \
}

#define PRIMITIVE_CASE(_type) __PRIMITIVE_CASE(_type, NO)
#define NULLABLE_PRIMITIVE_CASE(_type) __PRIMITIVE_CASE(_type, YES)

// Explicitly copy the block and retain it, since NSInvocation doesn't retain them
#define __COPY_BLOCK(block...) \
  id value = [block copy]; \
  CFBridgingRetain(value)

#if ABI21_0_0RCT_DEBUG
#define BLOCK_CASE(_block_args, _block) ABI21_0_0RCT_ARG_BLOCK(                  \
  if (json && ![json isKindOfClass:[NSNumber class]]) {                 \
    ABI21_0_0RCTLogArgumentError(weakSelf, index, json, "should be a function"); \
    return NO;                                                          \
  }                                                                     \
  __block BOOL didInvoke = NO;                                          \
  __COPY_BLOCK(^_block_args {                                           \
    if (checkCallbackMultipleInvocations(&didInvoke)) _block            \
  });                                                                   \
)
#else
#define BLOCK_CASE(_block_args, _block) \
  ABI21_0_0RCT_ARG_BLOCK( __COPY_BLOCK(^_block_args { _block }); )
#endif

  for (NSUInteger i = 2; i < numberOfArguments; i++) {
    const char *objcType = [methodSignature getArgumentTypeAtIndex:i];
    BOOL isNullableType = NO;
    ABI21_0_0RCTMethodArgument *argument = arguments[i - 2];
    NSString *typeName = argument.type;
    SEL selector = ABI21_0_0RCTConvertSelectorForType(typeName);
    if ([ABI21_0_0RCTConvert respondsToSelector:selector]) {
      switch (objcType[0]) {
        // Primitives
        case _C_CHR: PRIMITIVE_CASE(char)
        case _C_UCHR: PRIMITIVE_CASE(unsigned char)
        case _C_SHT: PRIMITIVE_CASE(short)
        case _C_USHT: PRIMITIVE_CASE(unsigned short)
        case _C_INT: PRIMITIVE_CASE(int)
        case _C_UINT: PRIMITIVE_CASE(unsigned int)
        case _C_LNG: PRIMITIVE_CASE(long)
        case _C_ULNG: PRIMITIVE_CASE(unsigned long)
        case _C_LNG_LNG: PRIMITIVE_CASE(long long)
        case _C_ULNG_LNG: PRIMITIVE_CASE(unsigned long long)
        case _C_FLT: PRIMITIVE_CASE(float)
        case _C_DBL: PRIMITIVE_CASE(double)
        case _C_BOOL: PRIMITIVE_CASE(BOOL)
        case _C_SEL: NULLABLE_PRIMITIVE_CASE(SEL)
        case _C_CHARPTR: NULLABLE_PRIMITIVE_CASE(const char *)
        case _C_PTR: NULLABLE_PRIMITIVE_CASE(void *)

        case _C_ID: {
          isNullableType = YES;
          id (*convert)(id, SEL, id) = (typeof(convert))objc_msgSend;
          ABI21_0_0RCT_ARG_BLOCK(
            id value = convert([ABI21_0_0RCTConvert class], selector, json);
            CFBridgingRetain(value);
          );
          break;
        }

        case _C_STRUCT_B: {
          NSMethodSignature *typeSignature = [ABI21_0_0RCTConvert methodSignatureForSelector:selector];
          NSInvocation *typeInvocation = [NSInvocation invocationWithMethodSignature:typeSignature];
          typeInvocation.selector = selector;
          typeInvocation.target = [ABI21_0_0RCTConvert class];

          [argumentBlocks addObject:^(__unused ABI21_0_0RCTBridge *bridge, NSUInteger index, id json) {
            void *returnValue = malloc(typeSignature.methodReturnLength);
            [typeInvocation setArgument:&json atIndex:2];
            [typeInvocation invoke];
            [typeInvocation getReturnValue:returnValue];
            [invocation setArgument:returnValue atIndex:index + 2];
            free(returnValue);
            return YES;
          }];
          break;
        }

        default: {
          static const char *blockType = @encode(typeof(^{}));
          if (!strcmp(objcType, blockType)) {
            BLOCK_CASE((NSArray *args), {
              [bridge enqueueCallback:json args:args];
            });
          } else {
            ABI21_0_0RCTLogError(@"Unsupported argument type '%@' in method %@.",
                        typeName, [self methodName]);
          }
        }
      }
    } else if ([typeName isEqualToString:@"ABI21_0_0RCTResponseSenderBlock"]) {
      BLOCK_CASE((NSArray *args), {
        [bridge enqueueCallback:json args:args];
      });
    } else if ([typeName isEqualToString:@"ABI21_0_0RCTResponseErrorBlock"]) {
      BLOCK_CASE((NSError *error), {
        [bridge enqueueCallback:json args:@[ABI21_0_0RCTJSErrorFromNSError(error)]];
      });
    } else if ([typeName isEqualToString:@"ABI21_0_0RCTPromiseResolveBlock"]) {
      ABI21_0_0RCTAssert(i == numberOfArguments - 2,
                @"The ABI21_0_0RCTPromiseResolveBlock must be the second to last parameter in %@",
                [self methodName]);
      BLOCK_CASE((id result), {
        [bridge enqueueCallback:json args:result ? @[result] : @[]];
      });
    } else if ([typeName isEqualToString:@"ABI21_0_0RCTPromiseRejectBlock"]) {
      ABI21_0_0RCTAssert(i == numberOfArguments - 1,
                @"The ABI21_0_0RCTPromiseRejectBlock must be the last parameter in %@",
                [self methodName]);
      BLOCK_CASE((NSString *code, NSString *message, NSError *error), {
        NSDictionary *errorJSON = ABI21_0_0RCTJSErrorFromCodeMessageAndNSError(code, message, error);
        [bridge enqueueCallback:json args:@[errorJSON]];
      });
    } else {
      // Unknown argument type
      ABI21_0_0RCTLogError(@"Unknown argument type '%@' in method %@. Extend ABI21_0_0RCTConvert to support this type.",
                  typeName, [self methodName]);
    }

#if ABI21_0_0RCT_DEBUG
    ABI21_0_0RCTNullability nullability = argument.nullability;
    if (!isNullableType) {
      if (nullability == ABI21_0_0RCTNullable) {
        ABI21_0_0RCTLogArgumentError(weakSelf, i - 2, typeName, "is marked as "
                            "nullable, but is not a nullable type.");
      }
      nullability = ABI21_0_0RCTNonnullable;
    }

    /**
     * Special case - Numbers are not nullable in Android, so we
     * don't support this for now. In future we may allow it.
     */
    if ([typeName isEqualToString:@"NSNumber"]) {
      BOOL unspecified = (nullability == ABI21_0_0RCTNullabilityUnspecified);
      if (!argument.unused && (nullability == ABI21_0_0RCTNullable || unspecified)) {
        ABI21_0_0RCTLogArgumentError(weakSelf, i - 2, typeName,
          [unspecified ? @"has unspecified nullability" : @"is marked as nullable"
           stringByAppendingString: @" but ReactABI21_0_0 requires that all NSNumber "
           "arguments are explicitly marked as `nonnull` to ensure "
           "compatibility with Android."].UTF8String);
      }
      nullability = ABI21_0_0RCTNonnullable;
    }

    if (nullability == ABI21_0_0RCTNonnullable) {
      ABI21_0_0RCTArgumentBlock oldBlock = argumentBlocks[i - 2];
      argumentBlocks[i - 2] = ^(ABI21_0_0RCTBridge *bridge, NSUInteger index, id json) {
        if (json != nil) {
          if (!oldBlock(bridge, index, json)) {
            return NO;
          }
          if (isNullableType) {
            // Check converted value wasn't null either, as method probably
            // won't gracefully handle a nil vallue for a nonull argument
            void *value;
            [invocation getArgument:&value atIndex:index + 2];
            if (value == NULL) {
              return NO;
            }
          }
          return YES;
        }
        ABI21_0_0RCTLogArgumentError(weakSelf, index, typeName, "must not be null");
        return NO;
      };
    }
#endif
  }

#if ABI21_0_0RCT_DEBUG
  const char *objcType = _invocation.methodSignature.methodReturnType;
  if (_methodInfo->isSync && objcType[0] != _C_ID) {
    ABI21_0_0RCTLogError(@"Return type of %@.%s should be (id) as the method is \"sync\"",
                ABI21_0_0RCTBridgeModuleNameForClass(_moduleClass), self.JSMethodName);
  }
#endif

  _argumentBlocks = argumentBlocks;
}

- (SEL)selector
{
  if (_selector == NULL) {
    ABI21_0_0RCT_PROFILE_BEGIN_EVENT(ABI21_0_0RCTProfileTagAlways, @"", (@{ @"module": NSStringFromClass(_moduleClass),
                                                          @"method": @(_methodInfo->objcName) }));
    [self processMethodSignature];
    ABI21_0_0RCT_PROFILE_END_EVENT(ABI21_0_0RCTProfileTagAlways, @"");
  }
  return _selector;
}

- (const char *)JSMethodName
{
  NSString *methodName = _JSMethodName;
  if (!methodName) {
    const char *jsName = _methodInfo->jsName;
    if (jsName && strlen(jsName) > 0) {
      methodName = @(jsName);
    } else {
      methodName = @(_methodInfo->objcName);
      NSRange colonRange = [methodName rangeOfString:@":"];
      if (colonRange.location != NSNotFound) {
        methodName = [methodName substringToIndex:colonRange.location];
      }
      methodName = [methodName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
      ABI21_0_0RCTAssert(methodName.length, @"%s is not a valid JS function name, please"
                " supply an alternative using ABI21_0_0RCT_REMAP_METHOD()", _methodInfo->objcName);
    }
    _JSMethodName = methodName;
  }
  return methodName.UTF8String;
}

- (ABI21_0_0RCTFunctionType)functionType
{
  if (strstr(_methodInfo->objcName, "ABI21_0_0RCTPromise") != NULL) {
    ABI21_0_0RCTAssert(!_methodInfo->isSync, @"Promises cannot be used in sync functions");
    return ABI21_0_0RCTFunctionTypePromise;
  } else if (_methodInfo->isSync) {
    return ABI21_0_0RCTFunctionTypeSync;
  } else {
    return ABI21_0_0RCTFunctionTypeNormal;
  }
}

- (id)invokeWithBridge:(ABI21_0_0RCTBridge *)bridge
                module:(id)module
             arguments:(NSArray *)arguments
{
  if (_argumentBlocks == nil) {
    [self processMethodSignature];
  }

#if ABI21_0_0RCT_DEBUG
  // Sanity check
  ABI21_0_0RCTAssert([module class] == _moduleClass, @"Attempted to invoke method \
            %@ on a module of class %@", [self methodName], [module class]);

  // Safety check
  if (arguments.count != _argumentBlocks.count) {
    NSInteger actualCount = arguments.count;
    NSInteger expectedCount = _argumentBlocks.count;

    // Subtract the implicit Promise resolver and rejecter functions for implementations of async functions
    if (self.functionType == ABI21_0_0RCTFunctionTypePromise) {
      actualCount -= 2;
      expectedCount -= 2;
    }

    ABI21_0_0RCTLogError(@"%@.%s was called with %zd arguments but expects %zd arguments. "
                @"If you haven\'t changed this method yourself, this usually means that "
                @"your versions of the native code and JavaScript code are out of sync. "
                @"Updating both should make this error go away.",
                ABI21_0_0RCTBridgeModuleNameForClass(_moduleClass), self.JSMethodName,
                actualCount, expectedCount);
    return nil;
  }
#endif

  // Set arguments
  NSUInteger index = 0;
  for (id json in arguments) {
    ABI21_0_0RCTArgumentBlock block = _argumentBlocks[index];
    if (!block(bridge, index, ABI21_0_0RCTNilIfNull(json))) {
      // Invalid argument, abort
      ABI21_0_0RCTLogArgumentError(self, index, json, "could not be processed. Aborting method call.");
      return nil;
    }
    index++;
  }

  // Invoke method
  [_invocation invokeWithTarget:module];

  ABI21_0_0RCTAssert(
    @encode(ABI21_0_0RCTArgumentBlock)[0] == _C_ID,
    @"Block type encoding has changed, it won't be released. A check for the block"
     "type encoding (%s) has to be added below.",
    @encode(ABI21_0_0RCTArgumentBlock)
  );

  index = 2;
  for (NSUInteger length = _invocation.methodSignature.numberOfArguments; index < length; index++) {
    if ([_invocation.methodSignature getArgumentTypeAtIndex:index][0] == _C_ID) {
      __unsafe_unretained id value;
      [_invocation getArgument:&value atIndex:index];

      if (value) {
        CFRelease((__bridge CFTypeRef)value);
      }
    }
  }

  if (_methodInfo->isSync) {
    void *returnValue;
    [_invocation getReturnValue:&returnValue];
    return (__bridge id)returnValue;
  }
  return nil;
}

- (NSString *)methodName
{
  if (!_selector) {
    [self processMethodSignature];
  }
  return [NSString stringWithFormat:@"-[%@ %s]", _moduleClass, sel_getName(_selector)];
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<%@: %p; exports %@ as %s(); type: %s>",
          [self class], self, [self methodName], self.JSMethodName, ABI21_0_0RCTFunctionDescriptorFromType(self.functionType)];
}

@end
