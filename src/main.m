//
//  edid-override — apply a custom EDID to a display on Apple Silicon
//
//  Uses the private IOAVServiceSetVirtualEDIDMode() API on DCPAVServiceProxy.
//  The override is volatile: it survives until the display is reset/reconnected,
//  so `watch` re-applies it when the display comes back.
//
//  This is a clean-room replacement for the runtime part of BetterDisplay's
//  custom-EDID feature. It does not modify or bypass BetterDisplay.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>

#import <float.h>
#import <signal.h>
#import <unistd.h>

// Private IOKit API. Declared here because it is not in the public SDK headers.
typedef CFTypeRef IOAVServiceRef;
extern IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
extern IOReturn IOAVServiceCopyEDID(IOAVServiceRef service, CFDataRef *edidData);
extern IOReturn IOAVServiceSetVirtualEDIDMode(IOAVServiceRef service, uint32_t *mode, CFDataRef edidData);

static NSString *const kToolName = @"edid-override";
static NSString *const kToolVersion = @"1.0.0";
static NSString *const kAgentLabel = @"local.edid-override";

// UW 2560x1080, vendor DNS (0x11d3), product 0x0a80, DTD 2560x1080@59.98.
static NSString *const kDefaultEDIDBase64 =
    @"AP///////wAR04AKAQAAAAEiAQSlQxx4Bu6Ro1RMmSYPUFQhCACBwNHAAQEBAQEBAQEBAQEBzUYAoKA4H0AwIDoAoRwhAAAaAjqAGHE4LUBYLEUAoRwhAAAeAAAA/QAwSx6gFAAKICAgICAgAAAA/ABVVyAyNTYweDEwODAKAKM=";

static const uint32_t kDefaultWidth = 2560;
static const uint32_t kDefaultHeight = 1080;
static const double kDefaultRefresh = 60.0;
static const double kRefreshTolerance = 2.0;

// Defined later.
static NSString *AgentPlistPath(void);
static int RunTool(NSString *path, NSArray<NSString *> *arguments, NSString **output);

#pragma mark - Errors and logging

static NSError *MakeError(NSString *format, ...) {
    va_list ap;
    va_start(ap, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    return [NSError errorWithDomain:@"EDIDOverride" code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static void LogMessage(NSString *format, ...) {
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSDateFormatter new];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });

    va_list ap;
    va_start(ap, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);

    fprintf(stderr, "%s %s\n", [formatter stringFromDate:[NSDate date]].UTF8String,
            message.UTF8String);
    fflush(stderr);
}

static const char *CString(NSString *string) {
    return string.length ? string.UTF8String : "(unknown)";
}

#pragma mark - EDID helpers

static int HexDigit(unichar c) {
    if (c >= '0' && c <= '9') return (int)(c - '0');
    if (c >= 'a' && c <= 'f') return (int)(c - 'a' + 10);
    if (c >= 'A' && c <= 'F') return (int)(c - 'A' + 10);
    return -1;
}

static BOOL EDIDLooksValid(NSData *data) {
    if (data.length < 128 || (data.length % 128) != 0) return NO;

    const uint8_t *bytes = data.bytes;
    static const uint8_t header[8] = {0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00};
    if (memcmp(bytes, header, sizeof(header)) != 0) return NO;

    for (NSUInteger block = 0; block < data.length / 128; block++) {
        uint8_t sum = 0;
        for (NSUInteger i = 0; i < 128; i++) {
            sum = (uint8_t)(sum + bytes[block * 128 + i]);
        }
        if (sum != 0) return NO;
    }
    return YES;
}

static NSData *EDIDFromText(NSString *text, NSError **error) {
    NSMutableString *clean = [NSMutableString stringWithCapacity:text.length];
    NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (![whitespace characterIsMember:c]) [clean appendFormat:@"%C", c];
    }

    if (clean.length == 0) {
        if (error) *error = MakeError(@"EDID string is empty");
        return nil;
    }

    BOOL isHex = (clean.length % 2 == 0 && clean.length >= 256);
    if (isHex) {
        for (NSUInteger i = 0; i < clean.length; i++) {
            if (HexDigit([clean characterAtIndex:i]) < 0) {
                isHex = NO;
                break;
            }
        }
    }

    NSData *data = nil;
    if (isHex) {
        NSMutableData *decoded = [NSMutableData dataWithCapacity:clean.length / 2];
        for (NSUInteger i = 0; i < clean.length; i += 2) {
            int hi = HexDigit([clean characterAtIndex:i]);
            int lo = HexDigit([clean characterAtIndex:i + 1]);
            uint8_t byte = (uint8_t)((hi << 4) | lo);
            [decoded appendBytes:&byte length:1];
        }
        data = decoded;
    } else {
        data = [[NSData alloc] initWithBase64EncodedString:clean options:0];
    }

    if (!data) {
        if (error) *error = MakeError(@"could not decode EDID as base64 or hex");
        return nil;
    }
    if (!EDIDLooksValid(data)) {
        if (error) {
            *error = MakeError(@"decoded EDID is invalid (need 128-byte blocks, "
                               @"00 ff ff ff ff ff ff 00 header, valid checksum); got %lu bytes",
                               (unsigned long)data.length);
        }
        return nil;
    }
    return data;
}

static NSData *EDIDFromFile(NSString *path, NSError **error) {
    NSError *readError = nil;
    NSData *raw = [NSData dataWithContentsOfFile:path options:0 error:&readError];
    if (!raw) {
        if (error) *error = MakeError(@"could not read %@: %@", path, readError.localizedDescription);
        return nil;
    }
    if (EDIDLooksValid(raw)) return raw;

    NSString *text = [[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding];
    if (!text) {
        if (error) *error = MakeError(@"%@ is neither raw EDID nor UTF-8 text", path);
        return nil;
    }
    return EDIDFromText(text, error);
}

static NSData *LoadEDID(NSString *argument, NSError **error) {
    if (!argument) return EDIDFromText(kDefaultEDIDBase64, error);
    if ([argument hasPrefix:@"@"]) return EDIDFromFile([argument substringFromIndex:1], error);
    if ([[NSFileManager defaultManager] fileExistsAtPath:argument]) {
        return EDIDFromFile(argument, error);
    }
    return EDIDFromText(argument, error);
}

static uint16_t EDIDVendor(NSData *edid) {
    if (edid.length < 12) return 0;
    const uint8_t *bytes = edid.bytes;
    return (uint16_t)((bytes[8] << 8) | bytes[9]);
}

static uint16_t EDIDProduct(NSData *edid) {
    if (edid.length < 12) return 0;
    const uint8_t *bytes = edid.bytes;
    return (uint16_t)(bytes[10] | (bytes[11] << 8));
}

static NSString *EDIDMonitorName(NSData *edid) {
    if (edid.length < 128) return nil;
    const uint8_t *bytes = edid.bytes;
    for (NSUInteger offset = 54; offset + 18 <= 126; offset += 18) {
        if (bytes[offset] == 0x00 && bytes[offset + 1] == 0x00 &&
            bytes[offset + 2] == 0x00 && bytes[offset + 3] == 0xfc) {
            NSData *nameData = [NSData dataWithBytes:bytes + offset + 5 length:13];
            NSString *name = [[NSString alloc] initWithData:nameData encoding:NSASCIIStringEncoding];
            name = [name stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (name.length) return name;
        }
    }
    return nil;
}

static NSString *EDIDManufacturer(NSData *edid) {
    if (edid.length < 10) return @"?";
    const uint8_t *bytes = edid.bytes;
    uint16_t value = (uint16_t)((bytes[8] << 8) | bytes[9]);
    char letters[4];
    letters[0] = (char)('A' + ((value >> 10) & 0x1f) - 1);
    letters[1] = (char)('A' + ((value >> 5) & 0x1f) - 1);
    letters[2] = (char)('A' + (value & 0x1f) - 1);
    letters[3] = '\0';
    return @(letters);
}

#pragma mark - AV services

@interface AVServiceEntry : NSObject
@property (nonatomic, readonly) io_service_t service;
@property (nonatomic, copy, readonly) NSString *location;
@property (nonatomic, readonly) uint64_t registryID;
- (instancetype)initWithService:(io_service_t)service location:(NSString *)location;
- (NSData *)copyEDID;
@end

@implementation AVServiceEntry

- (instancetype)initWithService:(io_service_t)service location:(NSString *)location {
    self = [super init];
    if (self) {
        _service = service; // takes ownership of the retained iterator result
        _location = [location copy] ?: @"";
        uint64_t registryID = 0;
        IORegistryEntryGetRegistryEntryID(service, &registryID);
        _registryID = registryID;
    }
    return self;
}

- (void)dealloc {
    if (_service) IOObjectRelease(_service);
}

- (NSData *)copyEDID {
    IOAVServiceRef av = IOAVServiceCreateWithService(kCFAllocatorDefault, self.service);
    if (!av) return nil;

    CFDataRef edid = NULL;
    IOReturn result = IOAVServiceCopyEDID(av, &edid);
    CFRelease(av);
    if (result != kIOReturnSuccess || !edid) return nil;
    return CFBridgingRelease(edid);
}

@end

static NSArray<AVServiceEntry *> *AllAVServices(void) {
    NSMutableArray<AVServiceEntry *> *result = [NSMutableArray array];
    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault,
                                                    IOServiceMatching("DCPAVServiceProxy"),
                                                    &iterator);
    if (kr != KERN_SUCCESS) return result;

    io_service_t service = IO_OBJECT_NULL;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        CFTypeRef locationRef = IORegistryEntrySearchCFProperty(service, kIOServicePlane,
                                                               CFSTR("Location"),
                                                               kCFAllocatorDefault,
                                                               kIORegistryIterateRecursively);
        NSString *location = locationRef ? CFBridgingRelease(locationRef) : @"";
        if (![location isKindOfClass:[NSString class]]) location = [location description];
        [result addObject:[[AVServiceEntry alloc] initWithService:service location:location]];
    }
    IOObjectRelease(iterator);
    return result;
}

static AVServiceEntry *FindAVService(NSString *location, NSData *edid) {
    NSArray<AVServiceEntry *> *services = AllAVServices();
    BOOL anyLocation = (location.length == 0 || [location isEqualToString:@"any"]);
    AVServiceEntry *fallback = nil;

    for (AVServiceEntry *entry in services) {
        if (!anyLocation && ![entry.location isEqualToString:location]) continue;
        if (!fallback) fallback = entry;

        // If EDID is readable (direct connection, not a KVM), prefer the service
        // that already reports the requested monitor.
        if (edid.length >= 12) {
            NSData *current = [entry copyEDID];
            if (current.length >= 12 &&
                EDIDVendor(current) == EDIDVendor(edid) &&
                EDIDProduct(current) == EDIDProduct(edid)) {
                return entry;
            }
        }
    }
    return fallback;
}

static IOReturn ApplyEDID(AVServiceEntry *entry, NSData *edid) {
    IOAVServiceRef av = IOAVServiceCreateWithService(kCFAllocatorDefault, entry.service);
    if (!av) return kIOReturnNoDevice;

    uint32_t mode = 1;
    IOReturn result = IOAVServiceSetVirtualEDIDMode(av, &mode, (__bridge CFDataRef)edid);
    CFRelease(av);
    return result;
}

static IOReturn ResetEDID(AVServiceEntry *entry) {
    IOAVServiceRef av = IOAVServiceCreateWithService(kCFAllocatorDefault, entry.service);
    if (!av) return kIOReturnNoDevice;

    IOReturn result = IOAVServiceSetVirtualEDIDMode(av, NULL, NULL);
    CFRelease(av);
    return result;
}

#pragma mark - Display helpers

static NSArray<NSNumber *> *OnlineDisplayIDs(void) {
    uint32_t count = 0;
    if (CGGetOnlineDisplayList(0, NULL, &count) != kCGErrorSuccess || count == 0) return @[];

    CGDirectDisplayID *ids = calloc(count, sizeof(CGDirectDisplayID));
    if (!ids) return @[];
    CGGetOnlineDisplayList(count, ids, &count);

    NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:count];
    for (uint32_t i = 0; i < count; i++) [result addObject:@(ids[i])];
    free(ids);
    return result;
}

static NSString *DisplayName(CGDirectDisplayID displayID) {
    for (NSScreen *screen in [NSScreen screens]) {
        NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
        if (number && number.unsignedIntValue == displayID) {
            return screen.localizedName ?: @"";
        }
    }
    return @"";
}

static void ModePixelSize(CGDisplayModeRef mode, size_t *width, size_t *height, BOOL *hiDPI) {
    size_t logicalWidth = CGDisplayModeGetWidth(mode);
    size_t logicalHeight = CGDisplayModeGetHeight(mode);
    size_t pixelWidth = CGDisplayModeGetPixelWidth(mode);
    size_t pixelHeight = CGDisplayModeGetPixelHeight(mode);

    if (pixelWidth == 0 || pixelHeight == 0) {
        pixelWidth = logicalWidth;
        pixelHeight = logicalHeight;
    }
    *width = pixelWidth;
    *height = pixelHeight;
    *hiDPI = (pixelWidth > logicalWidth || pixelHeight > logicalHeight);
}

static CGDisplayModeRef CopyBestMode(CGDirectDisplayID displayID,
                                     uint32_t width, uint32_t height,
                                     double refresh, BOOL wantHiDPI,
                                     double tolerance) {
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(displayID, NULL);
    if (!modes) return NULL;

    CGDisplayModeRef bestExact = NULL;
    CGDisplayModeRef bestUnknownRefresh = NULL;
    double bestExactScore = DBL_MAX;
    double bestUnknownScore = DBL_MAX;

    for (CFIndex i = 0; i < CFArrayGetCount(modes); i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        size_t modeWidth = 0, modeHeight = 0;
        BOOL modeHiDPI = NO;
        ModePixelSize(mode, &modeWidth, &modeHeight, &modeHiDPI);
        if (modeWidth != width || modeHeight != height || modeHiDPI != wantHiDPI) continue;

        double score = CGDisplayModeIsUsableForDesktopGUI(mode) ? 0.0 : 100.0;
        double modeRefresh = CGDisplayModeGetRefreshRate(mode);

        if (refresh <= 0) {
            if (score < bestExactScore) {
                bestExactScore = score;
                bestExact = mode;
            }
        } else if (modeRefresh > 0 && fabs(modeRefresh - refresh) <= tolerance) {
            if (score < bestExactScore) {
                bestExactScore = score;
                bestExact = mode;
            }
        } else if (modeRefresh <= 0) {
            if (score < bestUnknownScore) {
                bestUnknownScore = score;
                bestUnknownRefresh = mode;
            }
        }
    }

    CGDisplayModeRef result = bestExact ? bestExact : bestUnknownRefresh;
    if (result) CFRetain(result);
    CFRelease(modes);
    return result;
}

static BOOL DisplayHasMode(CGDirectDisplayID displayID,
                           uint32_t width, uint32_t height,
                           double refresh, BOOL hiDPI,
                           double tolerance) {
    CGDisplayModeRef mode = CopyBestMode(displayID, width, height, refresh, hiDPI, tolerance);
    if (!mode) return NO;
    CFRelease(mode);
    return YES;
}

static BOOL DisplayIsAtMode(CGDirectDisplayID displayID,
                            uint32_t width, uint32_t height,
                            double refresh, BOOL hiDPI,
                            double tolerance) {
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
    if (!mode) return NO;

    size_t modeWidth = 0, modeHeight = 0;
    BOOL modeHiDPI = NO;
    ModePixelSize(mode, &modeWidth, &modeHeight, &modeHiDPI);
    double modeRefresh = CGDisplayModeGetRefreshRate(mode);

    BOOL matches = (modeWidth == width && modeHeight == height && modeHiDPI == hiDPI);
    if (matches && refresh > 0 && modeRefresh > 0) {
        matches = (fabs(modeRefresh - refresh) <= tolerance);
    }
    CFRelease(mode);
    return matches;
}

static CGError SetDisplayMode(CGDirectDisplayID displayID,
                              uint32_t width, uint32_t height,
                              double refresh, BOOL hiDPI,
                              double tolerance) {
    CGDisplayModeRef mode = CopyBestMode(displayID, width, height, refresh, hiDPI, tolerance);
    if (!mode) return kCGErrorRangeCheck;

    CGError result = CGDisplaySetDisplayMode(displayID, mode, NULL);
    CFRelease(mode);
    return result;
}

static CGDirectDisplayID FindTargetDisplay(NSData *edid,
                                           CGDirectDisplayID explicitID,
                                           BOOL *found) {
    NSArray<NSNumber *> *ids = OnlineDisplayIDs();

    if (explicitID != 0) {
        for (NSNumber *number in ids) {
            if (number.unsignedIntValue == explicitID) {
                *found = YES;
                return explicitID;
            }
        }
        *found = NO;
        return 0;
    }

    if (edid.length >= 12) {
        uint16_t vendor = EDIDVendor(edid);
        uint16_t product = EDIDProduct(edid);
        for (NSNumber *number in ids) {
            CGDirectDisplayID displayID = number.unsignedIntValue;
            if (CGDisplayIsBuiltin(displayID)) continue;
            if (CGDisplayVendorNumber(displayID) == vendor &&
                CGDisplayModelNumber(displayID) == product) {
                *found = YES;
                return displayID;
            }
        }
    }

    // Before the EDID is applied the display may report vendor/model 0, so fall
    // back to the largest non-built-in display.
    CGDirectDisplayID best = 0;
    double bestArea = -1;
    for (NSNumber *number in ids) {
        CGDirectDisplayID displayID = number.unsignedIntValue;
        if (CGDisplayIsBuiltin(displayID)) continue;

        double area = 0;
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
        if (mode) {
            size_t width = 0, height = 0;
            BOOL hiDPI = NO;
            ModePixelSize(mode, &width, &height, &hiDPI);
            area = (double)width * (double)height;
            CFRelease(mode);
        }
        if (area > bestArea) {
            bestArea = area;
            best = displayID;
        }
    }

    *found = (best != 0);
    return best;
}

static BOOL WaitForTargetMode(NSData *edid,
                              CGDirectDisplayID explicitID,
                              uint32_t width, uint32_t height,
                              double refresh, BOOL hiDPI,
                              NSTimeInterval timeout,
                              CGDirectDisplayID *targetDisplayID) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (deadline.timeIntervalSinceNow > 0) {
        BOOL found = NO;
        CGDirectDisplayID displayID = FindTargetDisplay(edid, explicitID, &found);
        if (found && DisplayHasMode(displayID, width, height, refresh, hiDPI, kRefreshTolerance)) {
            if (targetDisplayID) *targetDisplayID = displayID;
            return YES;
        }
        usleep(250000);
    }
    return NO;
}

#pragma mark - Watcher

@interface Watcher : NSObject
@property (nonatomic, strong) NSData *edid;
@property (nonatomic, copy) NSString *location;
@property (nonatomic, assign) CGDirectDisplayID explicitDisplayID;
@property (nonatomic, assign) uint32_t width;
@property (nonatomic, assign) uint32_t height;
@property (nonatomic, assign) double refresh;
@property (nonatomic, assign) BOOL hiDPI;
@property (nonatomic, assign) BOOL setMode;
@property (nonatomic, assign) NSTimeInterval interval;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) CFAbsoluteTime lastApply;
@property (nonatomic, assign) CFAbsoluteTime lastModeSet;
@property (nonatomic, assign) BOOL lastServicePresent;
@property (nonatomic, assign) BOOL lastModeAvailable;
@property (nonatomic, assign) BOOL lastAtTarget;
@property (nonatomic, assign) BOOL checkScheduled;
- (void)start;
- (void)scheduleCheck;
- (void)check:(NSString *)reason;
@end

static dispatch_source_t gSignalSourceTERM = nil;
static dispatch_source_t gSignalSourceINT = nil;

static void InstallSignalHandlers(void) {
    signal(SIGTERM, SIG_IGN);
    signal(SIGINT, SIG_IGN);

    gSignalSourceTERM = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0,
                                               dispatch_get_main_queue());
    dispatch_source_set_event_handler(gSignalSourceTERM, ^{
        LogMessage(@"received SIGTERM, exiting");
        exit(0);
    });
    dispatch_resume(gSignalSourceTERM);

    gSignalSourceINT = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0,
                                              dispatch_get_main_queue());
    dispatch_source_set_event_handler(gSignalSourceINT, ^{
        LogMessage(@"received SIGINT, exiting");
        exit(0);
    });
    dispatch_resume(gSignalSourceINT);
}

static void DisplayReconfigurationCallback(CGDirectDisplayID display,
                                           CGDisplayChangeSummaryFlags flags,
                                           void *userInfo) {
    (void)display;
    (void)flags;
    Watcher *watcher = (__bridge Watcher *)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        [watcher scheduleCheck];
    });
}

@implementation Watcher

- (void)start {
    LogMessage(@"watch: target %ux%u @ %.2f Hz, HiDPI %@, interval %.1fs",
               self.width, self.height, self.refresh, self.hiDPI ? @"on" : @"off",
               self.interval);
    [self check:@"startup"];

    self.timer = [NSTimer timerWithTimeInterval:self.interval
                                         target:self
                                       selector:@selector(timerFired:)
                                       userInfo:nil
                                        repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];

    CGDisplayRegisterReconfigurationCallback(DisplayReconfigurationCallback,
                                             (__bridge void *)self);

    NSNotificationCenter *center = [[NSWorkspace sharedWorkspace] notificationCenter];
    [center addObserver:self
               selector:@selector(systemDidWake:)
                   name:NSWorkspaceDidWakeNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(systemDidWake:)
                   name:NSWorkspaceScreensDidWakeNotification
                 object:nil];

    [[NSRunLoop mainRunLoop] run];
}

- (void)timerFired:(NSTimer *)timer {
    [self check:@"timer"];
}

- (void)systemDidWake:(NSNotification *)notification {
    LogMessage(@"system wake notification");
    [self scheduleCheck];
}

- (void)scheduleCheck {
    if (self.checkScheduled) return;
    self.checkScheduled = YES;

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        Watcher *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.checkScheduled = NO;
        [strongSelf check:@"display-change"];
    });
}

- (void)check:(NSString *)reason {
    AVServiceEntry *service = FindAVService(self.location, self.edid);
    BOOL present = (service != nil);
    if (present != self.lastServicePresent) {
        LogMessage(@"%@ AV service %@", self.location, present ? @"appeared" : @"disappeared");
        self.lastServicePresent = present;
    }
    if (!present) {
        self.lastModeAvailable = NO;
        self.lastAtTarget = NO;
        return;
    }

    BOOL found = NO;
    CGDirectDisplayID displayID = FindTargetDisplay(self.edid, self.explicitDisplayID, &found);
    if (!found) {
        if (self.lastModeAvailable) LogMessage(@"target display not found");
        self.lastModeAvailable = NO;
        self.lastAtTarget = NO;
        return;
    }

    BOOL available = DisplayHasMode(displayID, self.width, self.height, self.refresh,
                                    self.hiDPI, kRefreshTolerance);
    BOOL atTarget = DisplayIsAtMode(displayID, self.width, self.height, self.refresh,
                                    self.hiDPI, kRefreshTolerance);

    if (available != self.lastModeAvailable) {
        LogMessage(@"%ux%u@%.2f mode %@ on display %u (%s)",
                   self.width, self.height, self.refresh,
                   available ? @"available" : @"missing",
                   displayID, CString(DisplayName(displayID)));
        self.lastModeAvailable = available;
    }
    if (atTarget != self.lastAtTarget) {
        LogMessage(@"display %u %@ target mode", displayID, atTarget ? @"is at" : @"is not at");
        self.lastAtTarget = atTarget;
    }

    if (self.setMode && available && !atTarget) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - self.lastModeSet >= 2.0) {
            CGError result = SetDisplayMode(displayID, self.width, self.height,
                                            self.refresh, self.hiDPI, kRefreshTolerance);
            self.lastModeSet = now;
            if (result == kCGErrorSuccess) {
                LogMessage(@"set display %u to %ux%u @ %.2f Hz",
                           displayID, self.width, self.height, self.refresh);
            } else {
                LogMessage(@"setting display mode failed: CGError %d", result);
            }
        }
        return;
    }

    if (!available) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - self.lastApply < 12.0) return;

        LogMessage(@"%@: %ux%u@%.2f mode missing; applying virtual EDID",
                   reason, self.width, self.height, self.refresh);
        IOReturn result = ApplyEDID(service, self.edid);
        self.lastApply = now;
        if (result != kIOReturnSuccess) {
            LogMessage(@"IOAVServiceSetVirtualEDIDMode failed: 0x%08x", result);
            return;
        }
        LogMessage(@"virtual EDID applied");

        if (self.setMode) {
            CGDirectDisplayID targetID = 0;
            if (WaitForTargetMode(self.edid, self.explicitDisplayID,
                                  self.width, self.height, self.refresh, self.hiDPI,
                                  8.0, &targetID)) {
                CGError modeResult = SetDisplayMode(targetID, self.width, self.height,
                                                    self.refresh, self.hiDPI,
                                                    kRefreshTolerance);
                self.lastModeSet = CFAbsoluteTimeGetCurrent();
                if (modeResult == kCGErrorSuccess) {
                    LogMessage(@"set display %u to %ux%u @ %.2f Hz",
                               targetID, self.width, self.height, self.refresh);
                } else {
                    LogMessage(@"setting display mode failed: CGError %d", modeResult);
                }
            } else {
                LogMessage(@"EDID applied, but target mode did not appear within 8s");
            }
        }
    }
}

@end

#pragma mark - Options

@interface Options : NSObject
@property (nonatomic, copy) NSString *command;
@property (nonatomic, copy) NSString *edidArgument;
@property (nonatomic, copy) NSString *location;
@property (nonatomic, assign) CGDirectDisplayID displayID;
@property (nonatomic, assign) uint32_t width;
@property (nonatomic, assign) uint32_t height;
@property (nonatomic, assign) double refresh;
@property (nonatomic, assign) BOOL hiDPI;
@property (nonatomic, assign) BOOL setMode;
@property (nonatomic, assign) BOOL dryRun;
@property (nonatomic, assign) BOOL allModes;
@property (nonatomic, assign) NSTimeInterval interval;
@property (nonatomic, copy) NSString *outputPath;
@property (nonatomic, assign) int vendor;
@property (nonatomic, assign) int product;
@property (nonatomic, copy) NSString *productName;
@property (nonatomic, assign) BOOL purge;
@end

@implementation Options

- (instancetype)init {
    self = [super init];
    if (self) {
        _command = @"status";
        _location = @"External";
        _width = kDefaultWidth;
        _height = kDefaultHeight;
        _refresh = kDefaultRefresh;
        _hiDPI = NO;
        _setMode = YES;
        _interval = 3.0;
        _vendor = 0;
        _product = 0;
    }
    return self;
}

@end

static NSString *NextValue(int *index, int argc, char **argv,
                           NSString *option, NSError **error) {
    if (*index + 1 >= argc) {
        if (error) *error = MakeError(@"missing value for %@", option);
        return nil;
    }
    (*index)++;
    return @(argv[*index]);
}

static BOOL ParseUInt32(NSString *string, uint32_t *value) {
    NSScanner *scanner = [NSScanner scannerWithString:string];
    unsigned long long parsed = 0;
    if (![scanner scanUnsignedLongLong:&parsed] || !scanner.isAtEnd || parsed > UINT32_MAX) {
        return NO;
    }
    *value = (uint32_t)parsed;
    return YES;
}

static BOOL ParseInt(NSString *string, int *value) {
    NSScanner *scanner = [NSScanner scannerWithString:string];
    int parsed = 0;
    if ([string hasPrefix:@"0x"] || [string hasPrefix:@"0X"]) {
        unsigned int hexValue = 0;
        if (![scanner scanHexInt:&hexValue] || !scanner.isAtEnd) return NO;
        parsed = (int)hexValue;
    } else {
        if (![scanner scanInt:&parsed] || !scanner.isAtEnd) return NO;
    }
    *value = parsed;
    return YES;
}

static BOOL ParseDouble(NSString *string, double *value) {
    NSScanner *scanner = [NSScanner scannerWithString:string];
    double parsed = 0;
    if (![scanner scanDouble:&parsed] || !scanner.isAtEnd) return NO;
    *value = parsed;
    return YES;
}

static BOOL ParseOptions(int argc, char **argv, Options *options, NSError **error) {
    if (argc >= 2) options.command = @(argv[1]);

    for (int i = 2; i < argc; i++) {
        NSString *argument = @(argv[i]);

        if ([argument isEqualToString:@"--edid"]) {
            NSString *value = NextValue(&i, argc, argv, argument, error);
            if (!value) return NO;
            options.edidArgument = value;
        } else if ([argument isEqualToString:@"--edid-file"]) {
            NSString *value = NextValue(&i, argc, argv, argument, error);
            if (!value) return NO;
            options.edidArgument = [@"@" stringByAppendingString:value];
        } else if ([argument isEqualToString:@"--location"]) {
            NSString *value = NextValue(&i, argc, argv, argument, error);
            if (!value) return NO;
            options.location = value;
        } else if ([argument isEqualToString:@"--display-id"]) {
            NSString *value = NextValue(&i, argc, argv, argument, error);
            if (!value) return NO;
            uint32_t parsed = 0;
            if (!ParseUInt32(value, &parsed)) {
                if (error) *error = MakeError(@"invalid --display-id: %@", value);
                return NO;
            }
            options.displayID = (CGDirectDisplayID)parsed;
        } else if ([argument isEqualToString:@"--width"]) {
            NSString *value = NextValue(&i, argc, argv, argument, error);
            if (!value) return NO;
            uint32_t parsed = 0;
            if (!ParseUInt32(value, &parsed) || parsed == 0) {
                if (error) *error = MakeError(@"invalid --width: %@", value);
                return NO;
            }
            options.width = parsed;
        } else if ([argument isEqualToString:@"--height"]) {
            NSString *value = NextValue(&i, argc, argv, argument, error);
            if (!value) return NO;
            uint32_t parsed = 0;
            if (!ParseUInt32(value, &parsed) || parsed == 0) {
                if (error) *error = MakeError(@"invalid --height: %@", value);
                return NO;
            }
            options.height = parsed;
        } else if ([argument isEqualToString:@"--refresh"]) {
            NSString *value = NextValue(&i, argc, argv, argument, error);
            if (!value) return NO;
            double parsed = 0;
            if (!ParseDouble(value, &parsed) || parsed <= 0) {
                if (error) *error = MakeError(@"invalid --refresh: %@", value);
                return NO;
            }
            options.refresh = parsed;
        } else if ([argument isEqualToString:@"--hidpi"]) {
            options.hiDPI = YES;
        } else if ([argument isEqualToString:@"--no-mode"]) {
            options.setMode = NO;
        } else if ([argument isEqualToString:@"--dry-run"]) {
            options.dryRun = YES;
        } else if ([argument isEqualToString:@"--all-modes"]) {
            options.allModes = YES;
        } else if ([argument isEqualToString:@"--interval"]) {
            NSString *value = NextValue(&i, argc, argv, argument, error);
            if (!value) return NO;
            double parsed = 0;
            if (!ParseDouble(value, &parsed) || parsed < 1.0) {
                if (error) *error = MakeError(@"invalid --interval: %@", value);
                return NO;
            }
            options.interval = parsed;
        } else if ([argument isEqualToString:@"--out"]) {
            NSString *value = NextValue(&i, argc, argv, argument, error);
            if (!value) return NO;
            options.outputPath = value;
        } else if ([argument isEqualToString:@"--vendor"]) {
            NSString *value = NextValue(&i, argc, argv, argument, error);
            if (!value) return NO;
            int parsed = 0;
            if (!ParseInt(value, &parsed)) {
                if (error) *error = MakeError(@"invalid --vendor: %@", value);
                return NO;
            }
            options.vendor = parsed;
        } else if ([argument isEqualToString:@"--product"]) {
            NSString *value = NextValue(&i, argc, argv, argument, error);
            if (!value) return NO;
            int parsed = 0;
            if (!ParseInt(value, &parsed)) {
                if (error) *error = MakeError(@"invalid --product: %@", value);
                return NO;
            }
            options.product = parsed;
        } else if ([argument isEqualToString:@"--name"]) {
            NSString *value = NextValue(&i, argc, argv, argument, error);
            if (!value) return NO;
            options.productName = value;
        } else if ([argument isEqualToString:@"--purge"]) {
            options.purge = YES;
        } else if ([argument isEqualToString:@"--help"] || [argument isEqualToString:@"-h"]) {
            options.command = @"help";
        } else {
            if (error) *error = MakeError(@"unknown option %@", argument);
            return NO;
        }
    }
    return YES;
}

#pragma mark - Commands

static void PrintUsage(FILE *stream) {
    fprintf(stream,
        "Usage: %s <command> [options]\n"
        "\n"
        "Commands:\n"
        "  list [--all-modes]          List AV services and displays\n"
        "  status                      Alias for list\n"
        "  apply [options]             Apply the virtual EDID and set the mode\n"
        "  reset                       Reset the virtual EDID to factory\n"
        "  set-mode [options]          Set the display mode without touching the EDID\n"
        "  watch [options]             Keep the EDID applied across reconnects and wake\n"
        "  install-agent [options]     Install a LaunchAgent running `watch`\n"
        "  uninstall-agent [--purge]   Remove the LaunchAgent\n"
        "  legacy-plist [--out PATH]   Generate a legacy display override plist\n"
        "  edid-info                   Parse and print the built-in or supplied EDID\n"
        "\n"
        "Options:\n"
        "  --edid <base64|hex|path>    EDID to apply (default: built-in UW 2560x1080)\n"
        "  --edid-file <path>          Read EDID from a file (base64, hex, or raw)\n"
        "  --location <name>           DCPAVServiceProxy location (default: External)\n"
        "  --display-id <id>           CGDirectDisplayID (default: match EDID vendor/product)\n"
        "  --width <n>                 Mode width (default: %u)\n"
        "  --height <n>                Mode height (default: %u)\n"
        "  --refresh <hz>              Mode refresh rate (default: %.0f)\n"
        "  --hidpi                     Select a HiDPI mode (default: off)\n"
        "  --no-mode                   Apply EDID only; do not set a display mode\n"
        "  --dry-run                   Show what apply would do\n"
        "  --all-modes                 List every mode\n"
        "  --interval <seconds>        watch poll interval (default: 3)\n"
        "  --out <path>                Output path for legacy-plist\n"
        "  --vendor <n>                legacy-plist vendor id (default: 0)\n"
        "  --product <n>               legacy-plist product id (default: 0)\n"
        "  --name <name>               legacy-plist display name\n"
        "  --purge                     uninstall-agent: remove support files\n"
        "  -h, --help                  Show this help\n"
        "\n"
        "The built-in EDID is volatile and is lost on reconnect. Use `watch` or\n"
        "`install-agent` to re-apply it automatically.\n",
        kToolName.UTF8String, kDefaultWidth, kDefaultHeight, kDefaultRefresh);
}

static void PrintCurrentMode(CGDirectDisplayID displayID) {
    CGDisplayModeRef current = CGDisplayCopyDisplayMode(displayID);
    if (!current) {
        printf("      current: (unavailable)\n");
        return;
    }
    size_t width = 0, height = 0;
    BOOL hiDPI = NO;
    ModePixelSize(current, &width, &height, &hiDPI);
    printf("      current: %zux%zu @ %.2f Hz%s\n", width, height,
           CGDisplayModeGetRefreshRate(current), hiDPI ? " (HiDPI)" : "");
    CFRelease(current);
}

static int CommandList(Options *options) {
    NSArray<AVServiceEntry *> *services = AllAVServices();
    printf("AV services (%lu):\n", (unsigned long)services.count);
    if (services.count == 0) printf("  (none)\n");
    for (AVServiceEntry *entry in services) {
        NSData *edid = [entry copyEDID];
        printf("  location=%-9s registry=0x%llx  EDID=",
               CString(entry.location), (unsigned long long)entry.registryID);
        if (edid) {
            printf("%lu bytes", (unsigned long)edid.length);
            if (edid.length >= 12) {
                printf(" vendor=0x%04x product=0x%04x", EDIDVendor(edid), EDIDProduct(edid));
            }
            printf("\n");
        } else {
            printf("unavailable\n");
        }
    }

    printf("\nDisplays:\n");
    NSArray<NSNumber *> *ids = OnlineDisplayIDs();
    if (ids.count == 0) printf("  (none)\n");
    for (NSNumber *number in ids) {
        CGDirectDisplayID displayID = number.unsignedIntValue;
        printf("  [%u] %s\n", displayID, CString(DisplayName(displayID)));
        printf("      vendor=0x%04x model=0x%04x serial=%u builtin=%s main=%s\n",
               CGDisplayVendorNumber(displayID), CGDisplayModelNumber(displayID),
               CGDisplaySerialNumber(displayID),
               CGDisplayIsBuiltin(displayID) ? "yes" : "no",
               CGDisplayIsMain(displayID) ? "yes" : "no");
        PrintCurrentMode(displayID);

        BOOL available = DisplayHasMode(displayID, options.width, options.height,
                                        options.refresh, options.hiDPI, kRefreshTolerance);
        printf("      target %ux%u @ %.2f Hz: %s\n",
               options.width, options.height, options.refresh,
               available ? "available" : "missing");

        if (options.allModes) {
            CFArrayRef modes = CGDisplayCopyAllDisplayModes(displayID, NULL);
            for (CFIndex i = 0; modes && i < CFArrayGetCount(modes); i++) {
                CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
                size_t width = 0, height = 0;
                BOOL hiDPI = NO;
                ModePixelSize(mode, &width, &height, &hiDPI);
                printf("        mode %3ld: %zux%zu @ %.2f Hz%s%s\n",
                       (long)i, width, height, CGDisplayModeGetRefreshRate(mode),
                       hiDPI ? " HiDPI" : "",
                       CGDisplayModeIsUsableForDesktopGUI(mode) ? "" : " [not GUI]");
            }
            if (modes) CFRelease(modes);
        }
    }

    printf("\nAuto-apply agent:\n");
    NSString *agentPlist = AgentPlistPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:agentPlist]) {
        printf("  not installed (run `%s install-agent`)\n", kToolName.UTF8String);
    } else {
        int status = RunTool(@"/bin/launchctl",
                             @[@"print",
                               [NSString stringWithFormat:@"gui/%u/%@", getuid(), kAgentLabel]],
                             NULL);
        printf("  %s: %s\n", CString(agentPlist),
               status == 0 ? "installed and loaded" : "installed but not loaded");
    }
    return 0;
}

static int CommandApply(Options *options) {
    NSError *error = nil;
    NSData *edid = LoadEDID(options.edidArgument, &error);
    if (!edid) {
        fprintf(stderr, "error: %s\n", CString(error.localizedDescription));
        return 1;
    }

    AVServiceEntry *service = FindAVService(options.location, edid);
    if (!service) {
        fprintf(stderr, "error: no %s DCPAVServiceProxy found\n", CString(options.location));
        return 1;
    }

    printf("EDID: %lu bytes, vendor=0x%04x (%s), product=0x%04x, name=%s\n",
           (unsigned long)edid.length, EDIDVendor(edid),
           CString(EDIDManufacturer(edid)), EDIDProduct(edid),
           CString(EDIDMonitorName(edid)));
    printf("service: location=%s registry=0x%llx\n",
           CString(service.location), (unsigned long long)service.registryID);

    if (options.dryRun) {
        printf("dry run: would call IOAVServiceSetVirtualEDIDMode(mode=1, %lu-byte EDID)\n",
               (unsigned long)edid.length);
        if (options.setMode) {
            printf("dry run: would set display to %ux%u @ %.2f Hz (HiDPI %s)\n",
                   options.width, options.height, options.refresh,
                   options.hiDPI ? "on" : "off");
        }
        return 0;
    }

    IOReturn result = ApplyEDID(service, edid);
    if (result != kIOReturnSuccess) {
        fprintf(stderr, "error: IOAVServiceSetVirtualEDIDMode failed: 0x%08x\n", result);
        return 1;
    }
    printf("virtual EDID applied\n");

    if (!options.setMode) return 0;

    CGDirectDisplayID displayID = 0;
    if (!WaitForTargetMode(edid, options.displayID, options.width, options.height,
                           options.refresh, options.hiDPI, 10.0, &displayID)) {
        fprintf(stderr, "warning: EDID applied, but %ux%u @ %.2f Hz did not appear within 10s\n",
                options.width, options.height, options.refresh);
        return 1;
    }

    CGError modeResult = SetDisplayMode(displayID, options.width, options.height,
                                        options.refresh, options.hiDPI, kRefreshTolerance);
    if (modeResult != kCGErrorSuccess) {
        fprintf(stderr, "error: CGDisplaySetDisplayMode failed: %d\n", modeResult);
        return 1;
    }

    printf("display %u set to %ux%u @ %.2f Hz\n",
           displayID, options.width, options.height, options.refresh);
    PrintCurrentMode(displayID);
    return 0;
}

static int CommandReset(Options *options) {
    AVServiceEntry *service = FindAVService(options.location, nil);
    if (!service) {
        fprintf(stderr, "error: no %s DCPAVServiceProxy found\n", CString(options.location));
        return 1;
    }

    IOReturn result = ResetEDID(service);
    if (result != kIOReturnSuccess) {
        fprintf(stderr, "error: IOAVServiceSetVirtualEDIDMode(NULL, NULL) failed: 0x%08x\n", result);
        return 1;
    }

    printf("virtual EDID reset requested on %s service (registry=0x%llx)\n",
           CString(service.location), (unsigned long long)service.registryID);

    // Give the display a moment to renegotiate before printing the new state.
    for (int attempt = 0; attempt < 20; attempt++) {
        BOOL stillAtTarget = NO;
        for (NSNumber *number in OnlineDisplayIDs()) {
            CGDirectDisplayID displayID = number.unsignedIntValue;
            if (CGDisplayIsBuiltin(displayID)) continue;
            if (DisplayIsAtMode(displayID, options.width, options.height,
                                options.refresh, options.hiDPI, kRefreshTolerance)) {
                stillAtTarget = YES;
                break;
            }
        }
        if (!stillAtTarget) break;
        usleep(250000);
    }

    NSArray<NSNumber *> *ids = OnlineDisplayIDs();
    for (NSNumber *number in ids) {
        CGDirectDisplayID displayID = number.unsignedIntValue;
        if (CGDisplayIsBuiltin(displayID)) continue;
        printf("display %u (%s):\n", displayID, CString(DisplayName(displayID)));
        PrintCurrentMode(displayID);
    }
    return 0;
}

static int CommandSetMode(Options *options) {
    NSError *error = nil;
    NSData *edid = LoadEDID(options.edidArgument, &error);
    if (!edid) {
        fprintf(stderr, "error: %s\n", CString(error.localizedDescription));
        return 1;
    }

    BOOL found = NO;
    CGDirectDisplayID displayID = FindTargetDisplay(edid, options.displayID, &found);
    if (!found) {
        fprintf(stderr, "error: target display not found\n");
        return 1;
    }

    CGDisplayModeRef mode = CopyBestMode(displayID, options.width, options.height,
                                         options.refresh, options.hiDPI, kRefreshTolerance);
    if (!mode) {
        fprintf(stderr, "error: %ux%u @ %.2f Hz (HiDPI %s) is not available on display %u\n",
                options.width, options.height, options.refresh,
                options.hiDPI ? "on" : "off", displayID);
        return 1;
    }

    CGError result = CGDisplaySetDisplayMode(displayID, mode, NULL);
    CFRelease(mode);
    if (result != kCGErrorSuccess) {
        fprintf(stderr, "error: CGDisplaySetDisplayMode failed: %d\n", result);
        return 1;
    }

    printf("display %u set to %ux%u @ %.2f Hz\n",
           displayID, options.width, options.height, options.refresh);
    PrintCurrentMode(displayID);
    return 0;
}

static int CommandWatch(Options *options) {
    NSError *error = nil;
    NSData *edid = LoadEDID(options.edidArgument, &error);
    if (!edid) {
        fprintf(stderr, "error: %s\n", CString(error.localizedDescription));
        return 1;
    }

    Watcher *watcher = [Watcher new];
    watcher.edid = edid;
    watcher.location = options.location;
    watcher.explicitDisplayID = options.displayID;
    watcher.width = options.width;
    watcher.height = options.height;
    watcher.refresh = options.refresh;
    watcher.hiDPI = options.hiDPI;
    watcher.setMode = options.setMode;
    watcher.interval = options.interval;

    InstallSignalHandlers();
    [watcher start];
    return 0;
}

#pragma mark - LaunchAgent

static NSString *ExpandTilde(NSString *path) {
    return [path stringByExpandingTildeInPath];
}

static NSString *SupportDirectory(void) {
    return ExpandTilde(@"~/Library/Application Support/EDIDOverride");
}

static NSString *AgentPlistPath(void) {
    return ExpandTilde(@"~/Library/LaunchAgents/local.edid-override.plist");
}

static NSString *AgentLogPath(void) {
    return ExpandTilde(@"~/Library/Logs/edid-override.log");
}

static int RunTool(NSString *path, NSArray<NSString *> *arguments, NSString **output) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = arguments;

    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;

    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        if (output) *output = error.localizedDescription ?: @"";
        return -1;
    }

    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (output) {
        *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    }
    return task.terminationStatus;
}

static NSString *ResolvedExecutablePath(void) {
    NSString *path = [NSProcessInfo processInfo].arguments[0];
    if (!path.isAbsolutePath) {
        path = [[[NSFileManager defaultManager] currentDirectoryPath]
                stringByAppendingPathComponent:path];
    }
    return [path stringByResolvingSymlinksInPath];
}

static void BootoutAgent(NSString *uid, NSString *plistPath) {
    RunTool(@"/bin/launchctl",
            @[@"bootout", [NSString stringWithFormat:@"gui/%@/%@", uid, kAgentLabel]],
            NULL);
    if (plistPath && [[NSFileManager defaultManager] fileExistsAtPath:plistPath]) {
        RunTool(@"/bin/launchctl",
                @[@"bootout", [NSString stringWithFormat:@"gui/%@", uid], plistPath],
                NULL);
    }
}

static int CommandInstallAgent(Options *options) {
    NSError *error = nil;
    NSData *edid = LoadEDID(options.edidArgument, &error);
    if (!edid) {
        fprintf(stderr, "error: %s\n", CString(error.localizedDescription));
        return 1;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *support = SupportDirectory();
    if (![fileManager createDirectoryAtPath:support
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:&error]) {
        fprintf(stderr, "error: could not create %s: %s\n",
                CString(support), CString(error.localizedDescription));
        return 1;
    }

    NSString *edidPath = [support stringByAppendingPathComponent:@"edid.bin"];
    if (![edid writeToFile:edidPath options:NSDataWritingAtomic error:&error]) {
        fprintf(stderr, "error: could not write %s: %s\n",
                CString(edidPath), CString(error.localizedDescription));
        return 1;
    }

    NSString *binarySource = ResolvedExecutablePath();
    NSString *binaryDestination = [support stringByAppendingPathComponent:@"edid-override"];
    if (![binarySource isEqualToString:binaryDestination]) {
        [fileManager removeItemAtPath:binaryDestination error:nil];
        if (![fileManager copyItemAtPath:binarySource
                                 toPath:binaryDestination
                                  error:&error]) {
            fprintf(stderr, "error: could not copy %s to %s: %s\n",
                    CString(binarySource), CString(binaryDestination),
                    CString(error.localizedDescription));
            return 1;
        }
    }
    [fileManager setAttributes:@{NSFilePosixPermissions: @0755}
                  ofItemAtPath:binaryDestination
                         error:nil];

    NSString *logPath = AgentLogPath();
    [fileManager createDirectoryAtPath:[logPath stringByDeletingLastPathComponent]
           withIntermediateDirectories:YES
                            attributes:nil
                                 error:nil];

    NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithObjects:
        binaryDestination,
        @"watch",
        @"--edid-file", edidPath,
        @"--location", options.location,
        @"--width", [NSString stringWithFormat:@"%u", options.width],
        @"--height", [NSString stringWithFormat:@"%u", options.height],
        @"--refresh", [NSString stringWithFormat:@"%.2f", options.refresh],
        @"--interval", [NSString stringWithFormat:@"%.1f", options.interval],
        nil];
    if (!options.setMode) [arguments addObject:@"--no-mode"];
    if (options.hiDPI) [arguments addObject:@"--hidpi"];
    if (options.displayID != 0) {
        [arguments addObject:@"--display-id"];
        [arguments addObject:[NSString stringWithFormat:@"%u", options.displayID]];
    }

    NSDictionary *plist = @{
        @"Label": kAgentLabel,
        @"ProgramArguments": arguments,
        @"RunAtLoad": @YES,
        @"KeepAlive": @YES,
        @"ThrottleInterval": @10,
        @"ProcessType": @"Background",
        @"LimitLoadToSessionType": @"Aqua",
        @"StandardOutPath": logPath,
        @"StandardErrorPath": logPath,
        @"WorkingDirectory": support,
    };

    NSData *plistData = [NSPropertyListSerialization dataWithPropertyList:plist
                                                                  format:NSPropertyListXMLFormat_v1_0
                                                                 options:0
                                                                   error:&error];
    if (!plistData) {
        fprintf(stderr, "error: could not serialize LaunchAgent: %s\n",
                CString(error.localizedDescription));
        return 1;
    }

    NSString *plistPath = AgentPlistPath();
    [fileManager createDirectoryAtPath:[plistPath stringByDeletingLastPathComponent]
           withIntermediateDirectories:YES
                            attributes:nil
                                 error:nil];
    if (![plistData writeToFile:plistPath options:NSDataWritingAtomic error:&error]) {
        fprintf(stderr, "error: could not write %s: %s\n",
                CString(plistPath), CString(error.localizedDescription));
        return 1;
    }

    NSString *uid = [NSString stringWithFormat:@"%u", getuid()];
    BootoutAgent(uid, plistPath);

    NSString *launchctlOutput = nil;
    int status = RunTool(@"/bin/launchctl",
                         @[@"bootstrap",
                           [NSString stringWithFormat:@"gui/%@", uid],
                           plistPath],
                         &launchctlOutput);
    if (status != 0) {
        fprintf(stderr, "warning: launchctl bootstrap failed (%d): %s\n",
                status, CString(launchctlOutput));
        fprintf(stderr, "load manually with: launchctl bootstrap gui/%s %s\n",
                CString(uid), CString(plistPath));
        return 1;
    }

    printf("installed %s\n", CString(plistPath));
    printf("agent: %s\n", CString(kAgentLabel));
    printf("log: %s\n", CString(logPath));
    return 0;
}

static int CommandUninstallAgent(Options *options) {
    NSString *uid = [NSString stringWithFormat:@"%u", getuid()];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *plistPath = AgentPlistPath();
    BootoutAgent(uid, plistPath);

    NSError *error = nil;
    if ([fileManager fileExistsAtPath:plistPath]) {
        if (![fileManager removeItemAtPath:plistPath error:&error]) {
            fprintf(stderr, "error: could not remove %s: %s\n",
                    CString(plistPath), CString(error.localizedDescription));
            return 1;
        }
        printf("removed %s\n", CString(plistPath));
    } else {
        printf("%s was not installed\n", CString(plistPath));
    }

    if (options.purge) {
        NSString *support = SupportDirectory();
        if ([fileManager fileExistsAtPath:support]) {
            if (![fileManager removeItemAtPath:support error:&error]) {
                fprintf(stderr, "error: could not remove %s: %s\n",
                        CString(support), CString(error.localizedDescription));
                return 1;
            }
            printf("removed %s\n", CString(support));
        }
    }
    return 0;
}

#pragma mark - Legacy plist

static int CommandLegacyPlist(Options *options) {
    NSError *error = nil;
    NSData *edid = LoadEDID(options.edidArgument, &error);
    if (!edid) {
        fprintf(stderr, "error: %s\n", CString(error.localizedDescription));
        return 1;
    }

    NSString *name = options.productName;
    if (!name) name = EDIDMonitorName(edid);
    if (!name) name = @"Custom EDID";

    NSDictionary *plist = @{
        @"DisplayVendorID": @(options.vendor),
        @"DisplayProductID": @(options.product),
        @"DisplayProductName": name,
        @"IODisplayEDID": edid,
    };

    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:&error];
    if (!data) {
        fprintf(stderr, "error: could not serialize plist: %s\n",
                CString(error.localizedDescription));
        return 1;
    }

    if (options.outputPath) {
        if (![data writeToFile:options.outputPath options:NSDataWritingAtomic error:&error]) {
            fprintf(stderr, "error: could not write %s: %s\n",
                    CString(options.outputPath), CString(error.localizedDescription));
            return 1;
        }
        printf("wrote %s\n", CString(options.outputPath));
    } else {
        fwrite(data.bytes, 1, data.length, stdout);
    }
    return 0;
}

static int CommandEDIDInfo(Options *options) {
    NSError *error = nil;
    NSData *edid = LoadEDID(options.edidArgument, &error);
    if (!edid) {
        fprintf(stderr, "error: %s\n", CString(error.localizedDescription));
        return 1;
    }

    printf("EDID: %lu bytes\n", (unsigned long)edid.length);
    printf("  header:   ok\n");
    printf("  checksum: ok\n");
    printf("  maker:    %s\n", CString(EDIDManufacturer(edid)));
    printf("  vendor:   0x%04x\n", EDIDVendor(edid));
    printf("  product:  0x%04x\n", EDIDProduct(edid));
    printf("  name:     %s\n", CString(EDIDMonitorName(edid)));

    const uint8_t *bytes = edid.bytes;
    for (int i = 0; i < 4; i++) {
        const uint8_t *dtd = bytes + 54 + i * 18;
        uint16_t pixelClock = (uint16_t)(dtd[0] | (dtd[1] << 8));
        if (pixelClock == 0) continue;

        uint32_t hactive = dtd[2] | ((dtd[4] & 0xf0) << 4);
        uint32_t hblank = dtd[3] | ((dtd[4] & 0x0f) << 8);
        uint32_t vactive = dtd[5] | ((dtd[7] & 0xf0) << 4);
        uint32_t vblank = dtd[6] | ((dtd[7] & 0x0f) << 8);
        double totalPixels = (double)(hactive + hblank) * (double)(vactive + vblank);
        double refresh = totalPixels > 0 ? (pixelClock * 10000.0 / totalPixels) : 0;

        printf("  DTD %d:    %ux%u @ %.2f Hz (pixel clock %.2f MHz)\n",
               i, hactive, vactive, refresh, pixelClock / 100.0);
    }
    return 0;
}


#pragma mark - main

int main(int argc, char **argv) {
    @autoreleasepool {
        Options *options = [Options new];
        NSError *error = nil;
        if (!ParseOptions(argc, argv, options, &error)) {
            fprintf(stderr, "error: %s\n\n", CString(error.localizedDescription));
            PrintUsage(stderr);
            return 2;
        }

        NSString *command = options.command;
        if ([command isEqualToString:@"help"] || [command isEqualToString:@"--help"]) {
            PrintUsage(stdout);
            return 0;
        }
        if ([command isEqualToString:@"version"] || [command isEqualToString:@"--version"]) {
            printf("%s %s\n", kToolName.UTF8String, kToolVersion.UTF8String);
            return 0;
        }
        if ([command isEqualToString:@"list"] || [command isEqualToString:@"status"]) {
            return CommandList(options);
        }
        if ([command isEqualToString:@"apply"]) {
            return CommandApply(options);
        }
        if ([command isEqualToString:@"reset"]) {
            return CommandReset(options);
        }
        if ([command isEqualToString:@"set-mode"]) {
            return CommandSetMode(options);
        }
        if ([command isEqualToString:@"watch"]) {
            return CommandWatch(options);
        }
        if ([command isEqualToString:@"install-agent"]) {
            return CommandInstallAgent(options);
        }
        if ([command isEqualToString:@"uninstall-agent"]) {
            return CommandUninstallAgent(options);
        }
        if ([command isEqualToString:@"legacy-plist"]) {
            return CommandLegacyPlist(options);
        }
        if ([command isEqualToString:@"edid-info"]) {
            return CommandEDIDInfo(options);
        }

        fprintf(stderr, "error: unknown command %s\n\n", CString(command));
        PrintUsage(stderr);
        return 2;
    }
}
