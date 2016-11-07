#import "RACObjCRuntimeUtilities.h"
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

NSString * const RACSelectorSignalErrorDomain = @"RACSelectorSignalErrorDomain";
const NSInteger RACSelectorSignalErrorMethodSwizzlingRace = 1;
const NSExceptionName RACSwizzleException = @"RACSwizzleException";

static NSString * const RACSignalForSelectorAliasPrefix = @"rac_swift_";
static NSString * const RACSubclassSuffix = @"_RACIntercepting";
static void *RACSubclassAssociationKey = &RACSubclassAssociationKey;

static NSMutableSet *swizzledClasses() {
	static NSMutableSet *set;
	static dispatch_once_t pred;

	dispatch_once(&pred, ^{
		set = [[NSMutableSet alloc] init];
	});

	return set;
}

@interface RACForwardingInfo : NSObject

@property (readonly, nonatomic) BOOL isTrigger;
@property (readonly, nonatomic, retain) id block;

-(instancetype) initWithBlock:(id)block isTrigger:(BOOL)isTrigger;

@end

@interface RACSwiftInvocationArguments (Private)

-(instancetype) initWithInvocation:(NSInvocation *)invocation;

@end

static SEL RACAliasForSelector(SEL originalSelector) {
	NSString *selectorName = NSStringFromSelector(originalSelector);
	return NSSelectorFromString([RACSignalForSelectorAliasPrefix stringByAppendingString:selectorName]);
}

static BOOL RACForwardInvocation(id self, NSInvocation *invocation) {
	SEL aliasSelector = RACAliasForSelector(invocation.selector);
	RACForwardingInfo* receiver = objc_getAssociatedObject(self, aliasSelector);

	Class class = object_getClass(invocation.target);
	BOOL respondsToAlias = [class instancesRespondToSelector:aliasSelector];
	if (respondsToAlias) {
		invocation.selector = aliasSelector;
		[invocation invoke];
	}

	if (receiver == nil) return respondsToAlias;

	if (receiver.isTrigger) {
		__block void(^block)(void) = receiver.block;
		block();
	} else {
		__block void(^block)(RACSwiftInvocationArguments*) = receiver.block;
		block([[RACSwiftInvocationArguments alloc] initWithInvocation:invocation]);

	}
	return YES;
}

static void RACSwizzleForwardInvocation(Class class) {
	SEL forwardInvocationSEL = @selector(forwardInvocation:);
	Method forwardInvocationMethod = class_getInstanceMethod(class, forwardInvocationSEL);

	// Preserve any existing implementation of -forwardInvocation:.
	void (*originalForwardInvocation)(id, SEL, NSInvocation *) = NULL;
	if (forwardInvocationMethod != NULL) {
		originalForwardInvocation = (__typeof__(originalForwardInvocation))method_getImplementation(forwardInvocationMethod);
	}

	// Set up a new version of -forwardInvocation:.
	//
	// If the selector has been passed to -rac_signalForSelector:, invoke
	// the aliased method, and forward the arguments to any attached signals.
	//
	// If the selector has not been passed to -rac_signalForSelector:,
	// invoke any existing implementation of -forwardInvocation:. If there
	// was no existing implementation, throw an unrecognized selector
	// exception.
	id newForwardInvocation = ^(id self, NSInvocation *invocation) {
		BOOL matched = RACForwardInvocation(self, invocation);
		if (matched) return;

		if (originalForwardInvocation == NULL) {
			[self doesNotRecognizeSelector:invocation.selector];
		} else {
			originalForwardInvocation(self, forwardInvocationSEL, invocation);
		}
	};

	class_replaceMethod(class, forwardInvocationSEL, imp_implementationWithBlock(newForwardInvocation), "v@:@");
}

Method rac_getImmediateInstanceMethod (Class aClass, SEL aSelector) {
	unsigned methodCount = 0;
	Method *methods = class_copyMethodList(aClass, &methodCount);
	Method foundMethod = NULL;

	for (unsigned methodIndex = 0;methodIndex < methodCount;++methodIndex) {
		if (method_getName(methods[methodIndex]) == aSelector) {
			foundMethod = methods[methodIndex];
			break;
		}
	}

	free(methods);
	return foundMethod;
}

static void RACSwizzleRespondsToSelector(Class class) {
	SEL respondsToSelectorSEL = @selector(respondsToSelector:);

	// Preserve existing implementation of -respondsToSelector:.
	Method respondsToSelectorMethod = class_getInstanceMethod(class, respondsToSelectorSEL);
	BOOL (*originalRespondsToSelector)(id, SEL, SEL) = (__typeof__(originalRespondsToSelector))method_getImplementation(respondsToSelectorMethod);

	// Set up a new version of -respondsToSelector: that returns YES for methods
	// added by -rac_signalForSelector:.
	//
	// If the selector has a method defined on the receiver's actual class, and
	// if that method's implementation is _objc_msgForward, then returns whether
	// the instance has a signal for the selector.
	// Otherwise, call the original -respondsToSelector:.
	id newRespondsToSelector = ^ BOOL (id self, SEL selector) {
		Method method = rac_getImmediateInstanceMethod(class, selector);

		if (method != NULL && method_getImplementation(method) == _objc_msgForward) {
			SEL aliasSelector = RACAliasForSelector(selector);
			if (objc_getAssociatedObject(self, aliasSelector) != nil) return YES;
		}

		return originalRespondsToSelector(self, respondsToSelectorSEL, selector);
	};

	class_replaceMethod(class, respondsToSelectorSEL, imp_implementationWithBlock(newRespondsToSelector), method_getTypeEncoding(respondsToSelectorMethod));
}

static void RACSwizzleGetClass(Class class, Class statedClass) {
	SEL selector = @selector(class);
	Method method = class_getInstanceMethod(class, selector);
	IMP newIMP = imp_implementationWithBlock(^(id self) {
		return statedClass;
	});
	class_replaceMethod(class, selector, newIMP, method_getTypeEncoding(method));
}

static void RACSwizzleMethodSignatureForSelector(Class class) {
	IMP newIMP = imp_implementationWithBlock(^(id self, SEL selector) {
		// Don't send the -class message to the receiver because we've changed
		// that to return the original class.
		Class actualClass = object_getClass(self);
		Method method = class_getInstanceMethod(actualClass, selector);
		if (method == NULL) {
			// Messages that the original class dynamically implements fall
			// here.
			//
			// Call the original class' -methodSignatureForSelector:.
			struct objc_super target = {
				.super_class = class_getSuperclass(class),
				.receiver = self,
			};
			NSMethodSignature * (*messageSend)(struct objc_super *, SEL, SEL) = (__typeof__(messageSend))objc_msgSendSuper;
			return messageSend(&target, @selector(methodSignatureForSelector:), selector);
		}

		char const *encoding = method_getTypeEncoding(method);
		return [NSMethodSignature signatureWithObjCTypes:encoding];
	});

	SEL selector = @selector(methodSignatureForSelector:);
	Method methodSignatureForSelectorMethod = class_getInstanceMethod(class, selector);
	class_replaceMethod(class, selector, newIMP, method_getTypeEncoding(methodSignatureForSelectorMethod));
}

// It's hard to tell which struct return types use _objc_msgForward, and
// which use _objc_msgForward_stret instead, so just exclude all struct, array,
// union, complex and vector return types.
static void RACCheckTypeEncoding(const char *typeEncoding) {
#if !NS_BLOCK_ASSERTIONS
	// Some types, including vector types, are not encoded. In these cases the
	// signature starts with the size of the argument frame.
	NSCAssert(*typeEncoding < '1' || *typeEncoding > '9', @"unknown method return type not supported in type encoding: %s", typeEncoding);
	NSCAssert(strstr(typeEncoding, "(") != typeEncoding, @"union method return type not supported");
	NSCAssert(strstr(typeEncoding, "{") != typeEncoding, @"struct method return type not supported");
	NSCAssert(strstr(typeEncoding, "[") != typeEncoding, @"array method return type not supported");
	NSCAssert(strstr(typeEncoding, @encode(_Complex float)) != typeEncoding, @"complex float method return type not supported");
	NSCAssert(strstr(typeEncoding, @encode(_Complex double)) != typeEncoding, @"complex double method return type not supported");
	NSCAssert(strstr(typeEncoding, @encode(_Complex long double)) != typeEncoding, @"complex long double method return type not supported");

#endif // !NS_BLOCK_ASSERTIONS
}

static const char *RACSignatureForUndefinedSelector(SEL selector) {
	const char *name = sel_getName(selector);
	NSMutableString *signature = [NSMutableString stringWithString:@"v@:"];

	while ((name = strchr(name, ':')) != NULL) {
		[signature appendString:@"@"];
		name++;
	}

	return signature.UTF8String;
}

static Class RACSwizzleClass(NSObject *self) {
	Class statedClass = self.class;
	Class baseClass = object_getClass(self);

	// The "known dynamic subclass" is the subclass generated by RAC.
	// It's stored as an associated object on every instance that's already
	// been swizzled, so that even if something else swizzles the class of
	// this instance, we can still access the RAC generated subclass.
	Class knownDynamicSubclass = objc_getAssociatedObject(self, RACSubclassAssociationKey);
	if (knownDynamicSubclass != Nil) return knownDynamicSubclass;

	NSString *className = NSStringFromClass(baseClass);

	if (statedClass != baseClass) {
		// If the class is already lying about what it is, it's probably a KVO
		// dynamic subclass or something else that we shouldn't subclass
		// ourselves.
		//
		// Just swizzle -forwardInvocation: in-place. Since the object's class
		// was almost certainly dynamically changed, we shouldn't see another of
		// these classes in the hierarchy.
		//
		// Additionally, swizzle -respondsToSelector: because the default
		// implementation may be ignorant of methods added to this class.
		@synchronized (swizzledClasses()) {
			if (![swizzledClasses() containsObject:className]) {
				RACSwizzleForwardInvocation(baseClass);
				RACSwizzleRespondsToSelector(baseClass);
				RACSwizzleGetClass(baseClass, statedClass);
				RACSwizzleGetClass(object_getClass(baseClass), statedClass);
				RACSwizzleMethodSignatureForSelector(baseClass);
				[swizzledClasses() addObject:className];
			}
		}

		return baseClass;
	}

	const char *subclassName = [className stringByAppendingString:RACSubclassSuffix].UTF8String;
	Class subclass = objc_getClass(subclassName);

	if (subclass == nil) {
		subclass = objc_allocateClassPair(baseClass, subclassName, 0);
		if (subclass == nil) return nil;

		RACSwizzleForwardInvocation(subclass);
		RACSwizzleRespondsToSelector(subclass);

		RACSwizzleGetClass(subclass, statedClass);
		RACSwizzleGetClass(object_getClass(subclass), statedClass);

		RACSwizzleMethodSignatureForSelector(subclass);

		objc_registerClassPair(subclass);
	}

	object_setClass(self, subclass);
	objc_setAssociatedObject(self, RACSubclassAssociationKey, subclass, OBJC_ASSOCIATION_ASSIGN);
	return subclass;
}

@implementation NSObject (RACObjCRuntimeUtilities)

-(BOOL) _rac_setupInvocationObservationForSelector:(SEL)selector protocol:(Protocol *)protocol argsReceiver:(void (^)(RACSwiftInvocationArguments*))receiverBlock {
	return [self _rac_setupInvocationObservationForSelector:selector protocol:protocol isTrigger:false receiver:receiverBlock];
}

-(BOOL) _rac_setupInvocationObservationForSelector:(SEL)selector protocol:(Protocol *)protocol receiver:(void (^)(void))receiverBlock {
	return [self _rac_setupInvocationObservationForSelector:selector protocol:protocol isTrigger:true receiver:receiverBlock];
}

-(BOOL) _rac_setupInvocationObservationForSelector:(SEL)selector protocol:(Protocol *)protocol isTrigger:(BOOL)isTrigger receiver:(id)receiverBlock {
	SEL aliasSelector = RACAliasForSelector(selector);

	RACForwardingInfo* existingReceiver = objc_getAssociatedObject(self, aliasSelector);
	if (existingReceiver != nil) return NO;

	Class class = RACSwizzleClass(self);
	NSCAssert(class != nil, @"Could not swizzle class of %@", self);

	RACForwardingInfo* receiver = [[RACForwardingInfo alloc] initWithBlock:receiverBlock isTrigger:isTrigger];
	objc_setAssociatedObject(self, aliasSelector, receiver, OBJC_ASSOCIATION_RETAIN);

	Method targetMethod = class_getInstanceMethod(class, selector);
	if (targetMethod == NULL) {
		const char *typeEncoding;
		if (protocol == NULL) {
			typeEncoding = RACSignatureForUndefinedSelector(selector);
		} else {
			// Look for the selector as an optional instance method.
			struct objc_method_description methodDescription = protocol_getMethodDescription(protocol, selector, NO, YES);

			if (methodDescription.name == NULL) {
				// Then fall back to looking for a required instance
				// method.
				methodDescription = protocol_getMethodDescription(protocol, selector, YES, YES);
				NSCAssert(methodDescription.name != NULL, @"Selector %@ does not exist in <%s>", NSStringFromSelector(selector), protocol_getName(protocol));
			}

			typeEncoding = methodDescription.types;
		}

		RACCheckTypeEncoding(typeEncoding);

		// Define the selector to call -forwardInvocation:.
		if (!class_addMethod(class, selector, _objc_msgForward, typeEncoding)) {
			@throw [[NSException alloc] initWithName:RACSwizzleException reason:nil userInfo:nil];
		}
	} else if (method_getImplementation(targetMethod) != _objc_msgForward) {
		// Make a method alias for the existing method implementation.
		const char *typeEncoding = method_getTypeEncoding(targetMethod);

		RACCheckTypeEncoding(typeEncoding);

		BOOL addedAlias __attribute__((unused)) = class_addMethod(class, aliasSelector, method_getImplementation(targetMethod), typeEncoding);
		NSCAssert(addedAlias, @"Original implementation for %@ is already copied to %@ on %@", NSStringFromSelector(selector), NSStringFromSelector(aliasSelector), class);

		// Redefine the selector to call -forwardInvocation:.
		class_replaceMethod(class, selector, _objc_msgForward, method_getTypeEncoding(targetMethod));
	}
	
	return YES;
}
@end

@implementation RACSwiftInvocationArguments
NSInvocation* invocation;

-(instancetype) initWithInvocation:(NSInvocation *)inv {
	self = [super init];
	if (self) {
		invocation = inv;
	}
	return self;
}

-(NSInteger)count {
	return [[invocation methodSignature] numberOfArguments];
}

-(const char *)argumentTypeAt:(NSInteger)position {
	return [[invocation methodSignature] getArgumentTypeAtIndex:position];
}

-(void)copyArgumentAt:(NSInteger)position to:(void *)buffer {
	[invocation getArgument:buffer atIndex:position];
}

-(NSString*)selectorStringAt:(NSInteger)position {
	SEL selector;
	[invocation getArgument:&selector atIndex:position];
	return NSStringFromSelector(selector);
}

@end

@implementation RACForwardingInfo

-(instancetype) initWithBlock:(id)block isTrigger:(BOOL)isTrigger {
	self = [super init];
	if (self) {
		_block = block;
		_isTrigger = isTrigger;
	}
	return self;
}

@end
