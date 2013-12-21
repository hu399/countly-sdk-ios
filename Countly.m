// Countly.m
//
// This code is provided under the MIT License.
//
// Please visit www.count.ly for more information.

#pragma mark - Directives

#ifndef COUNTLY_DEBUG
#define COUNTLY_DEBUG 0
#endif

#ifndef COUNTLY_IGNORE_INVALID_CERTIFICATES
#define COUNTLY_IGNORE_INVALID_CERTIFICATES 1
#endif

#if COUNTLY_DEBUG
#   define COUNTLY_LOG(fmt, ...) NSLog(fmt, ##__VA_ARGS__)
#else
#   define COUNTLY_LOG(...)
#endif

#define COUNTLY_VERSION "1.0"
#define COUNTLY_DEFAULT_UPDATE_INTERVAL 60.0
#define COUNTLY_EVENT_SEND_THRESHOLD 10

#import "Countly.h"
#import "Countly_OpenUDID.h"
#import <UIKit/UIKit.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <CoreTelephony/CTCarrier.h>
#import "CountlyDB.h"

#include <sys/types.h>
#include <sys/sysctl.h>


#pragma mark - Helper Functions

NSString* CountlyJSONFromObject(id object);
NSString* CountlyURLEscapedString(NSString* string);
NSString* CountlyURLUnescapedString(NSString* string);

NSString* CountlyJSONFromObject(id object)
{
	NSError *error = nil;
	NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];
	
	if (error)
        COUNTLY_LOG(@"%@", [err description]);
	
	return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
}

NSString* CountlyURLEscapedString(NSString* string)
{
	// Encode all the reserved characters, per RFC 3986
	// (<http://www.ietf.org/rfc/rfc3986.txt>)
	CFStringRef escaped =
    CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault,
                                            (CFStringRef)string,
                                            NULL,
                                            (CFStringRef)@"!*'();:@&=+$,/?%#[]",
                                            kCFStringEncodingUTF8);
	return [(NSString*)escaped autorelease];
}

NSString* CountlyURLUnescapedString(NSString* string)
{
	NSMutableString *resultString = [NSMutableString stringWithString:string];
	[resultString replaceOccurrencesOfString:@"+"
								  withString:@" "
									 options:NSLiteralSearch
									   range:NSMakeRange(0, [resultString length])];
	return [resultString stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
}


#pragma mark - CountlyDeviceInfo

@interface CountlyDeviceInfo : NSObject

+ (NSString *)udid;
+ (NSString *)device;
+ (NSString *)osVersion;
+ (NSString *)carrier;
+ (NSString *)resolution;
+ (NSString *)locale;
+ (NSString *)appVersion;

+ (NSString *)metrics;

@end

@implementation CountlyDeviceInfo

+ (NSString *)udid
{
	return [Countly_OpenUDID value];
}

+ (NSString *)device
{
    size_t size;
    sysctlbyname("hw.machine", NULL, &size, NULL, 0);
    char *machine = malloc(size);
    sysctlbyname("hw.machine", machine, &size, NULL, 0);
    NSString *platform = [NSString stringWithUTF8String:machine];
    free(machine);
    return platform;
}

+ (NSString *)osVersion
{
	return [[UIDevice currentDevice] systemVersion];
}

+ (NSString *)carrier
{
	if (NSClassFromString(@"CTTelephonyNetworkInfo"))
	{
		CTTelephonyNetworkInfo *netinfo = [[[CTTelephonyNetworkInfo alloc] init] autorelease];
		CTCarrier *carrier = [netinfo subscriberCellularProvider];
		return [carrier carrierName];
	}
    
	return nil;
}

+ (NSString *)resolution
{
	CGRect bounds = [[UIScreen mainScreen] bounds];
	CGFloat scale = [[UIScreen mainScreen] respondsToSelector:@selector(scale)] ? [[UIScreen mainScreen] scale] : 1.f;
	CGSize res = CGSizeMake(bounds.size.width * scale, bounds.size.height * scale);
	NSString *result = [NSString stringWithFormat:@"%gx%g", res.width, res.height];
    
	return result;
}

+ (NSString *)locale
{
	return [[NSLocale currentLocale] localeIdentifier];
}

+ (NSString *)appVersion
{
    NSString *result = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if ([result length] == 0)
        result = [[NSBundle mainBundle] objectForInfoDictionaryKey:(NSString*)kCFBundleVersionKey];
    
    return result;
}

+ (NSString *)metrics
{
    NSMutableDictionary* metricsDictionary = [NSMutableDictionary dictionary];
	[metricsDictionary setObject:CountlyDeviceInfo.device forKey:@"_device"];
	[metricsDictionary setObject:@"iOS" forKey:@"_os"];
	[metricsDictionary setObject:CountlyDeviceInfo.osVersion forKey:@"_os_version"];
    
	NSString *carrier = CountlyDeviceInfo.carrier;
	if (carrier)
        [metricsDictionary setObject:carrier forKey:@"_carrier"];

	[metricsDictionary setObject:CountlyDeviceInfo.resolution forKey:@"_resolution"];
	[metricsDictionary setObject:CountlyDeviceInfo.locale forKey:@"_locale"];
	[metricsDictionary setObject:CountlyDeviceInfo.appVersion forKey:@"_app_version"];
	
	return CountlyURLEscapedString(CountlyJSONFromObject(metricsDictionary));
}

@end


#pragma mark - CountlyEvent

@interface CountlyEvent : NSObject
{
}

@property (nonatomic, copy) NSString *key;
@property (nonatomic, retain) NSDictionary *segmentation;
@property (nonatomic, assign) int count;
@property (nonatomic, assign) double sum;
@property (nonatomic, assign) double timestamp;

@end

@implementation CountlyEvent

@synthesize key = key_;
@synthesize segmentation = segmentation_;
@synthesize count = count_;
@synthesize sum = sum_;
@synthesize timestamp = timestamp_;

- (id)init
{
    if (self = [super init])
    {
        key_ = nil;
        segmentation_ = nil;
        count_ = 0;
        sum_ = 0;
        timestamp_ = 0;
    }
    return self;
}

- (void)dealloc
{
    [key_ release];
    [segmentation_ release];
    [super dealloc];
}

@end


#pragma mark - CountlyEventQueue

@interface CountlyEventQueue : NSObject

@end


@implementation CountlyEventQueue

- (void)dealloc
{
    [super dealloc];
}

- (NSUInteger)count
{
    @synchronized (self)
    {
        return [[CountlyDB sharedInstance] getEventCount];
    }
}


- (NSString *)events
{
    NSString *result = @"[";
    
    @synchronized (self)
    {
        NSArray* events = [[[CountlyDB sharedInstance] getEvents] copy];
        for (NSUInteger i = 0; i < events.count; ++i)
        {
            CountlyEvent *event = [self convertNSManagedObjectToCountlyEvent:[events objectAtIndex:i]];
            
            result = [result stringByAppendingString:@"{"];
            
            result = [result stringByAppendingFormat:@"\"%@\":\"%@\"", @"key", event.key];
            
            if (event.segmentation)
            {
                NSString *segmentation = @"{";
                
                NSArray *keys = [event.segmentation allKeys];
                for (NSUInteger i = 0; i < keys.count; ++i)
                {
                    NSString *key = [keys objectAtIndex:i];
                    NSString *value = [event.segmentation objectForKey:key];
                    
                    segmentation = [segmentation stringByAppendingFormat:@"\"%@\":\"%@\"", key, value];
                    
                    if (i + 1 < keys.count)
                        segmentation = [segmentation stringByAppendingString:@","];
                }
                segmentation = [segmentation stringByAppendingString:@"}"];
                
                result = [result stringByAppendingFormat:@",\"%@\":%@", @"segmentation", segmentation];
            }
            
            result = [result stringByAppendingFormat:@",\"%@\":%d", @"count", event.count];
            
            if (event.sum > 0)
                result = [result stringByAppendingFormat:@",\"%@\":%g", @"sum", event.sum];
            
            result = [result stringByAppendingFormat:@",\"%@\":%ld", @"timestamp", (time_t)event.timestamp];
            
            result = [result stringByAppendingString:@"}"];
            
            if (i + 1 < events.count)
                result = [result stringByAppendingString:@","];
            
            [[CountlyDB sharedInstance] removeFromQueue:[events objectAtIndex:i]];
            
        }
        
        [events release];
    }
    
    result = [result stringByAppendingString:@"]"];
    
    result = CountlyURLEscapedString(result);
    
	return result;
}

-(CountlyEvent*) convertNSManagedObjectToCountlyEvent:(NSManagedObject*)managedObject
{
    CountlyEvent* event = [[CountlyEvent alloc] init];
    event.key = [managedObject valueForKey:@"key"];
    if ([managedObject valueForKey:@"count"])
        event.count = ((NSNumber*) [managedObject valueForKey:@"count"]).doubleValue;
    if ([managedObject valueForKey:@"sum"])
        event.sum = ((NSNumber*) [managedObject valueForKey:@"sum"]).doubleValue;
    if ([managedObject valueForKey:@"timestamp"])
        event.timestamp = ((NSNumber*) [managedObject valueForKey:@"timestamp"]).doubleValue;
    if ([managedObject valueForKey:@"segmentation"])
        event.segmentation = [managedObject valueForKey:@"segmentation"];
    return event;
}

- (void)recordEvent:(NSString *)key count:(int)count
{
    @synchronized (self)
    {
        NSArray* events = [[CountlyDB sharedInstance] getEvents];
        for (NSManagedObject* obj in events)
        {
            CountlyEvent *event = [self convertNSManagedObjectToCountlyEvent:obj];
            if ([event.key isEqualToString:key])
            {
                event.count += count;
                event.timestamp = (event.timestamp + time(NULL)) / 2;
                
                [obj setValue:[NSNumber numberWithDouble:event.count] forKey:@"count"];
                [obj setValue:[NSNumber numberWithDouble:event.timestamp] forKey:@"timestamp"];
                
                [[CountlyDB sharedInstance] saveContext];
                return;
            }
        }
        
        CountlyEvent *event = [[CountlyEvent alloc] init];
        event.key = key;
        event.count = count;
        event.timestamp = time(NULL);
        
        [[CountlyDB sharedInstance] createEvent:event.key count:event.count sum:event.sum segmentation:event.segmentation timestamp:event.timestamp];
        
        [event release];
    }
}

- (void)recordEvent:(NSString *)key count:(int)count sum:(double)sum
{
    @synchronized (self)
    {
        NSArray* events = [[CountlyDB sharedInstance] getEvents];
        for (NSManagedObject* obj in events)
        {
            CountlyEvent *event = [self convertNSManagedObjectToCountlyEvent:obj];
            if ([event.key isEqualToString:key])
            {
                event.count += count;
                event.sum += sum;
                event.timestamp = (event.timestamp + time(NULL)) / 2;
                
                [obj setValue:[NSNumber numberWithDouble:event.count] forKey:@"count"];
                [obj setValue:[NSNumber numberWithDouble:event.sum] forKey:@"sum"];
                [obj setValue:[NSNumber numberWithDouble:event.timestamp] forKey:@"timestamp"];
                
                [[CountlyDB sharedInstance] saveContext];
                
                return;
            }
        }
        
        CountlyEvent *event = [[CountlyEvent alloc] init];
        event.key = key;
        event.count = count;
        event.sum = sum;
        event.timestamp = time(NULL);
        
        [[CountlyDB sharedInstance] createEvent:event.key count:event.count sum:event.sum segmentation:event.segmentation timestamp:event.timestamp];
        
        [event release];
    }
}

- (void)recordEvent:(NSString *)key segmentation:(NSDictionary *)segmentation count:(int)count;
{
    @synchronized (self)
    {
        
        NSArray* events = [[CountlyDB sharedInstance] getEvents];
        for (NSManagedObject* obj in events)
        {
            CountlyEvent *event = [self convertNSManagedObjectToCountlyEvent:obj];
            if ([event.key isEqualToString:key] &&
                event.segmentation && [event.segmentation isEqualToDictionary:segmentation])
            {
                event.count += count;
                event.timestamp = (event.timestamp + time(NULL)) / 2;
                
                [obj setValue:[NSNumber numberWithDouble:event.count] forKey:@"count"];
                [obj setValue:[NSNumber numberWithDouble:event.timestamp] forKey:@"timestamp"];
                
                [[CountlyDB sharedInstance] saveContext];
                
                return;
            }
        }
        
        CountlyEvent *event = [[CountlyEvent alloc] init];
        event.key = key;
        event.segmentation = segmentation;
        event.count = count;
        event.timestamp = time(NULL);
        
        [[CountlyDB sharedInstance] createEvent:event.key count:event.count sum:event.sum segmentation:event.segmentation timestamp:event.timestamp];
        
        [event release];
    }
}

- (void)recordEvent:(NSString *)key segmentation:(NSDictionary *)segmentation count:(int)count sum:(double)sum;
{
    @synchronized (self)
    {
        
        NSArray* events = [[[CountlyDB sharedInstance] getEvents] copy];
        for (NSManagedObject* obj in events)
        {
            CountlyEvent *event = [self convertNSManagedObjectToCountlyEvent:obj];
            if ([event.key isEqualToString:key] &&
                event.segmentation && [event.segmentation isEqualToDictionary:segmentation])
            {
                event.count += count;
                event.sum += sum;
                event.timestamp = (event.timestamp + time(NULL)) / 2;
                
                [obj setValue:[NSNumber numberWithDouble:event.count] forKey:@"count"];
                [obj setValue:[NSNumber numberWithDouble:event.sum] forKey:@"sum"];
                [obj setValue:[NSNumber numberWithDouble:event.timestamp] forKey:@"timestamp"];
                
                [[CountlyDB sharedInstance] saveContext];
                
                return;
            }
        }
        
        CountlyEvent *event = [[CountlyEvent alloc] init];
        event.key = key;
        event.segmentation = segmentation;
        event.count = count;
        event.sum = sum;
        event.timestamp = time(NULL);
        
        [[CountlyDB sharedInstance] createEvent:event.key count:event.count sum:event.sum segmentation:event.segmentation timestamp:event.timestamp];
        
        [event release];
    }
}

@end


#pragma mark - CountlyConnectionQueue

@interface CountlyConnectionQueue : NSObject
{
	NSURLConnection *connection_;
	UIBackgroundTaskIdentifier bgTask_;
	NSString *appKey;
	NSString *appHost;
}

+ (instancetype)sharedInstance;

@property (nonatomic, copy) NSString *appKey;
@property (nonatomic, copy) NSString *appHost;

@end


@implementation CountlyConnectionQueue : NSObject

@synthesize appKey;
@synthesize appHost;

+ (instancetype)sharedInstance
{
    static CountlyConnectionQueue *s_sharedCountlyConnectionQueue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{s_sharedCountlyConnectionQueue = self.new;});
	return s_sharedCountlyConnectionQueue;
}

- (id)init
{
	if (self = [super init])
	{
		connection_ = nil;
        bgTask_ = UIBackgroundTaskInvalid;
        appKey = nil;
        appHost = nil;
	}
	return self;
}

- (void) tick
{
    NSArray* dataQueue = [[[CountlyDB sharedInstance] getQueue] copy];
    
    if (connection_ != nil || bgTask_ != UIBackgroundTaskInvalid || [dataQueue count] == 0)
        return;
    
    UIApplication *app = [UIApplication sharedApplication];
    bgTask_ = [app beginBackgroundTaskWithExpirationHandler:^{
		[app endBackgroundTask:bgTask_];
		bgTask_ = UIBackgroundTaskInvalid;
    }];
    
    NSString *data = [[dataQueue objectAtIndex:0] valueForKey:@"post"];
    NSString *urlString = [NSString stringWithFormat:@"%@/i?%@", self.appHost, data];
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    connection_ = [NSURLConnection connectionWithRequest:request delegate:self];
    
    [dataQueue release];
}

- (void)beginSession
{
	NSString *data = [NSString stringWithFormat:@"app_key=%@&device_id=%@&timestamp=%ld&sdk_version="COUNTLY_VERSION"&begin_session=1&metrics=%@",
					  appKey,
					  [CountlyDeviceInfo udid],
					  time(NULL),
					  [CountlyDeviceInfo metrics]];
    
    [[CountlyDB sharedInstance] addToQueue:data];
    
	[self tick];
}

- (void)updateSessionWithDuration:(int)duration
{
	NSString *data = [NSString stringWithFormat:@"app_key=%@&device_id=%@&timestamp=%ld&session_duration=%d",
					  appKey,
					  [CountlyDeviceInfo udid],
					  time(NULL),
					  duration];
    
    [[CountlyDB sharedInstance] addToQueue:data];
    
	[self tick];
}

- (void)endSessionWithDuration:(int)duration
{
	NSString *data = [NSString stringWithFormat:@"app_key=%@&device_id=%@&timestamp=%ld&end_session=1&session_duration=%d",
					  appKey,
					  [CountlyDeviceInfo udid],
					  time(NULL),
					  duration];
    
    [[CountlyDB sharedInstance] addToQueue:data];
    
	[self tick];
}

- (void)recordEvents:(NSString *)events
{
	NSString *data = [NSString stringWithFormat:@"app_key=%@&device_id=%@&timestamp=%ld&events=%@",
					  appKey,
					  [CountlyDeviceInfo udid],
					  time(NULL),
					  events];
    
    [[CountlyDB sharedInstance] addToQueue:data];
    
	[self tick];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    
    NSArray* dataQueue = [[[CountlyDB sharedInstance] getQueue] copy];
    
	COUNTLY_LOG(@"ok -> %@", [dataQueue objectAtIndex:0]);
    
    UIApplication *app = [UIApplication sharedApplication];
    if (bgTask_ != UIBackgroundTaskInvalid)
    {
        [app endBackgroundTask:bgTask_];
        bgTask_ = UIBackgroundTaskInvalid;
    }
    
    connection_ = nil;
    
    [[CountlyDB sharedInstance] removeFromQueue:[dataQueue objectAtIndex:0]];
    
    [dataQueue release];
    
    [self tick];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)err
{
    #if COUNTLY_DEBUG
        NSArray* dataQueue = [[[CountlyDB sharedInstance] getQueue] copy];
        COUNTLY_LOG(@"error -> %@: %@", [dataQueue objectAtIndex:0], err);
    #endif
    
    UIApplication *app = [UIApplication sharedApplication];
    if (bgTask_ != UIBackgroundTaskInvalid)
    {
        [app endBackgroundTask:bgTask_];
        bgTask_ = UIBackgroundTaskInvalid;
    }
    
    connection_ = nil;
}

#if COUNTLY_IGNORE_INVALID_CERTIFICATES
- (void)connection:(NSURLConnection *)connection willSendRequestForAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
{
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust])
        [challenge.sender useCredential:[NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust] forAuthenticationChallenge:challenge];
    
    [[challenge sender] continueWithoutCredentialForAuthenticationChallenge:challenge];
}
#endif

- (void)dealloc
{
	[super dealloc];
	
	if (connection_)
		[connection_ cancel];
	
	self.appKey = nil;
	self.appHost = nil;
}

@end


#pragma mark - Countly Core

@implementation Countly

+ (instancetype)sharedInstance
{
    static Countly *s_sharedCountly = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{s_sharedCountly = self.new;});
	return s_sharedCountly;
}

- (id)init
{
	if (self = [super init])
	{
		timer = nil;
		isSuspended = NO;
		unsentSessionLength = 0;
        eventQueue = [[CountlyEventQueue alloc] init];
		
		[[NSNotificationCenter defaultCenter] addObserver:self
												 selector:@selector(didEnterBackgroundCallBack:)
													 name:UIApplicationDidEnterBackgroundNotification
												   object:nil];
		[[NSNotificationCenter defaultCenter] addObserver:self
												 selector:@selector(willEnterForegroundCallBack:)
													 name:UIApplicationWillEnterForegroundNotification
												   object:nil];
		[[NSNotificationCenter defaultCenter] addObserver:self
												 selector:@selector(willTerminateCallBack:)
													 name:UIApplicationWillTerminateNotification
												   object:nil];
	}
	return self;
}

- (void)start:(NSString *)appKey withHost:(NSString *)appHost
{
	timer = [NSTimer scheduledTimerWithTimeInterval:COUNTLY_DEFAULT_UPDATE_INTERVAL
											 target:self
										   selector:@selector(onTimer:)
										   userInfo:nil
											repeats:YES];
	lastTime = CFAbsoluteTimeGetCurrent();
	[[CountlyConnectionQueue sharedInstance] setAppKey:appKey];
	[[CountlyConnectionQueue sharedInstance] setAppHost:appHost];
	[[CountlyConnectionQueue sharedInstance] beginSession];
}

- (void)recordEvent:(NSString *)key count:(int)count
{
    [eventQueue recordEvent:key count:count];
    
    if (eventQueue.count >= COUNTLY_EVENT_SEND_THRESHOLD)
        [[CountlyConnectionQueue sharedInstance] recordEvents:[eventQueue events]];
}

- (void)recordEvent:(NSString *)key count:(int)count sum:(double)sum
{
    [eventQueue recordEvent:key count:count sum:sum];
    
    if (eventQueue.count >= COUNTLY_EVENT_SEND_THRESHOLD)
        [[CountlyConnectionQueue sharedInstance] recordEvents:[eventQueue events]];
}

- (void)recordEvent:(NSString *)key segmentation:(NSDictionary *)segmentation count:(int)count
{
    [eventQueue recordEvent:key segmentation:segmentation count:count];
    
    if (eventQueue.count >= COUNTLY_EVENT_SEND_THRESHOLD)
        [[CountlyConnectionQueue sharedInstance] recordEvents:[eventQueue events]];
}

- (void)recordEvent:(NSString *)key segmentation:(NSDictionary *)segmentation count:(int)count sum:(double)sum
{
    [eventQueue recordEvent:key segmentation:segmentation count:count sum:sum];
    
    if (eventQueue.count >= COUNTLY_EVENT_SEND_THRESHOLD)
        [[CountlyConnectionQueue sharedInstance] recordEvents:[eventQueue events]];
}

- (void)onTimer:(NSTimer *)timer
{
	if (isSuspended == YES)
		return;
    
	double currTime = CFAbsoluteTimeGetCurrent();
	unsentSessionLength += currTime - lastTime;
	lastTime = currTime;
    
	int duration = unsentSessionLength;
	[[CountlyConnectionQueue sharedInstance] updateSessionWithDuration:duration];
	unsentSessionLength -= duration;
    
    if (eventQueue.count > 0)
        [[CountlyConnectionQueue sharedInstance] recordEvents:[eventQueue events]];
}

- (void)suspend
{
	isSuspended = YES;
    
    if (eventQueue.count > 0)
        [[CountlyConnectionQueue sharedInstance] recordEvents:[eventQueue events]];
    
	double currTime = CFAbsoluteTimeGetCurrent();
	unsentSessionLength += currTime - lastTime;
    
	int duration = unsentSessionLength;
	[[CountlyConnectionQueue sharedInstance] endSessionWithDuration:duration];
	unsentSessionLength -= duration;
}

- (void)resume
{
	lastTime = CFAbsoluteTimeGetCurrent();
    
	[[CountlyConnectionQueue sharedInstance] beginSession];
    
	isSuspended = NO;
}

- (void)exit
{
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillEnterForegroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillTerminateNotification object:nil];
	
	if (timer)
    {
        [timer invalidate];
        timer = nil;
    }
    
    [eventQueue release];
	
	[super dealloc];
}

- (void)didEnterBackgroundCallBack:(NSNotification *)notification
{
	COUNTLY_LOG(@"Countly didEnterBackgroundCallBack");
	[self suspend];
    
}

- (void)willEnterForegroundCallBack:(NSNotification *)notification
{
	COUNTLY_LOG(@"Countly willEnterForegroundCallBack");
	[self resume];
}

- (void)willTerminateCallBack:(NSNotification *)notification
{
	COUNTLY_LOG(@"Countly willTerminateCallBack");
    [[CountlyDB sharedInstance] saveContext];
	[self exit];
}

@end
