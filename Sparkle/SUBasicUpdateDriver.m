//
//  SUBasicUpdateDriver.m
//  Sparkle
//
//  Created by Andy Matuschak on 4/23/08.
//  Copyright 2008 Andy Matuschak. All rights reserved.
//

#import "SUBasicUpdateDriver.h"

#import "SUHost.h"
#import "SUDSAVerifier.h"
#import "SUInstaller.h"
#import "SUStandardVersionComparator.h"
#import "SUUnarchiver.h"
#import "SUConstants.h"
#import "SULog.h"
#import "SUPlainInstaller.h"
#import "SUPlainInstallerInternals.h"
#import "SUBinaryDeltaCommon.h"
#import "SUCodeSigningVerifier.h"
#import "SUUpdater_Private.h"
#import "SUXPCInstaller.h"

CF_EXPORT CFDictionaryRef DMCopyHTTPRequestHeaders(CFBundleRef appBundle, CFDataRef httpBodyData);

@interface SUBasicUpdateDriver ()

@property (strong) SUAppcastItem *updateItem;
@property (strong) NSURLDownload *download;
@property (copy) NSString *downloadPath;

@property (strong) SUAppcastItem *nonDeltaUpdateItem;
@property (copy) NSString *tempDir;
@property (copy) NSString *relaunchPath;

@end

@implementation SUBasicUpdateDriver

@synthesize updateItem;
@synthesize download;
@synthesize downloadPath;

@synthesize nonDeltaUpdateItem;
@synthesize tempDir;
@synthesize relaunchPath;

- (void)checkForUpdatesAtURL:(NSURL *)URL host:(SUHost *)aHost
{
    [super checkForUpdatesAtURL:URL host:aHost];
	if ([aHost isRunningOnReadOnlyVolume])
	{
        [self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SURunningFromDiskImageError userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:SULocalizedString(@"%1$@ can't be updated when it's running from a read-only volume like a disk image or an optical drive. Move %1$@ to your Applications folder, relaunch it from there, and try again.", nil), [aHost name]] }]];
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    request.allHTTPHeaderFields = [self.updater httpHeaders];
    [self updateURLRequestHTTPHeaders:request];
    
    SUAppcast *appcast = [[SUAppcast alloc] init];

    [appcast setUserAgentString:[self.updater userAgentString]];
    [appcast setHttpHeaders:request.allHTTPHeaderFields];
    [appcast fetchAppcastFromURL:URL completionBlock:^(NSError *error) {
        if (error) {
            [self abortUpdateWithError:error];
        } else {
            [self appcastDidFinishLoading:appcast];
        }
    }];
}

- (id<SUVersionComparison>)versionComparator
{
    id<SUVersionComparison> comparator = nil;

    // Give the delegate a chance to provide a custom version comparator
    if ([[self.updater delegate] respondsToSelector:@selector(versionComparatorForUpdater:)]) {
        comparator = [[self.updater delegate] versionComparatorForUpdater:self.updater];
    }

    // If we don't get a comparator from the delegate, use the default comparator
    if (!comparator) {
        comparator = [SUStandardVersionComparator defaultComparator];
    }

    return comparator;
}

- (BOOL)isItemNewer:(SUAppcastItem *)ui
{
    return [[self versionComparator] compareVersion:[self.host version] toVersion:[ui versionString]] == NSOrderedAscending;
}

- (BOOL)hostSupportsItem:(SUAppcastItem *)ui
{
	if (([ui minimumSystemVersion] == nil || [[ui minimumSystemVersion] isEqualToString:@""]) &&
        ([ui maximumSystemVersion] == nil || [[ui maximumSystemVersion] isEqualToString:@""])) { return YES; }

    BOOL minimumVersionOK = TRUE;
    BOOL maximumVersionOK = TRUE;

    // Check minimum and maximum System Version
    if ([ui minimumSystemVersion] != nil && ![[ui minimumSystemVersion] isEqualToString:@""]) {
        minimumVersionOK = [[SUStandardVersionComparator defaultComparator] compareVersion:[ui minimumSystemVersion] toVersion:[SUHost systemVersionString]] != NSOrderedDescending;
    }
    if ([ui maximumSystemVersion] != nil && ![[ui maximumSystemVersion] isEqualToString:@""]) {
        maximumVersionOK = [[SUStandardVersionComparator defaultComparator] compareVersion:[ui maximumSystemVersion] toVersion:[SUHost systemVersionString]] != NSOrderedAscending;
    }

    return minimumVersionOK && maximumVersionOK;
}

- (BOOL)itemContainsSkippedVersion:(SUAppcastItem *)ui
{
    NSString *skippedVersion = [self.host objectForUserDefaultsKey:SUSkippedVersionKey];
	if (skippedVersion == nil) { return NO; }
    return [[self versionComparator] compareVersion:[ui versionString] toVersion:skippedVersion] != NSOrderedDescending;
}

- (BOOL)itemContainsValidUpdate:(SUAppcastItem *)ui
{
    return ui && [self hostSupportsItem:ui] && [self isItemNewer:ui] && ![self itemContainsSkippedVersion:ui];
}

- (void)appcastDidFinishLoading:(SUAppcast *)ac
{
    if ([[self.updater delegate] respondsToSelector:@selector(updater:didFinishLoadingAppcast:)]) {
        [[self.updater delegate] updater:self.updater didFinishLoadingAppcast:ac];
    }

    NSDictionary *userInfo = (ac != nil) ? @{ SUUpdaterAppcastNotificationKey: ac } : nil;
    [[NSNotificationCenter defaultCenter] postNotificationName:SUUpdaterDidFinishLoadingAppCastNotification object:self.updater userInfo:userInfo];

    SUAppcastItem *item = nil;

    // Now we have to find the best valid update in the appcast.
    if ([[self.updater delegate] respondsToSelector:@selector(bestValidUpdateInAppcast:forUpdater:)]) // Does the delegate want to handle it?
    {
        item = [[self.updater delegate] bestValidUpdateInAppcast:ac forUpdater:self.updater];
	}
	else // If not, we'll take care of it ourselves.
    {
        // Find the first update we can actually use.
        NSEnumerator *updateEnumerator = [[ac items] objectEnumerator];
        do {
            item = [updateEnumerator nextObject];
        } while (item && ![self hostSupportsItem:item]);

        SUAppcastItem *deltaUpdateItem = [item deltaUpdates][[self.host version]];
        if (deltaUpdateItem && [self hostSupportsItem:deltaUpdateItem]) {
            self.nonDeltaUpdateItem = item;
            item = deltaUpdateItem;
        }
    }

    if ([self itemContainsValidUpdate:item]) {
        self.updateItem = item;
        [self didFindValidUpdate];
    } else {
        self.updateItem = nil;
        [self didNotFindUpdate];
    }
}

- (void)didFindValidUpdate
{
    assert(self.updateItem);

    if ([[self.updater delegate] respondsToSelector:@selector(updater:didFindValidUpdate:)]) {
        [[self.updater delegate] updater:self.updater didFindValidUpdate:self.updateItem];
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:SUUpdaterDidFindValidUpdateNotification
                                                        object:self.updater
                                                      userInfo:@{ SUUpdaterAppcastItemNotificationKey: self.updateItem }];
    [self downloadUpdate];
}

- (void)didNotFindUpdate
{
    if ([[self.updater delegate] respondsToSelector:@selector(updaterDidNotFindUpdate:)]) {
        [[self.updater delegate] updaterDidNotFindUpdate:self.updater];
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:SUUpdaterDidNotFindUpdateNotification object:self.updater];

    [self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain
                                                   code:SUNoUpdateError
                                               userInfo:@{
                                                   NSLocalizedDescriptionKey: [NSString stringWithFormat:SULocalizedString(@"You already have the newest version of %@.", "'Error' message when the user checks for updates but is already current or the feed doesn't contain any updates. (not necessarily shown in UI)"), self.host.name]
                                               }]];
}

- (void)updateURLRequestHTTPHeaders:(NSMutableURLRequest *)request
{
    CFBundleRef hostBundle = CFBundleCreate(kCFAllocatorDefault, (__bridge CFURLRef)[NSURL fileURLWithPath:self.host.bundlePath]);
    NSDictionary *devmateHeaders = (__bridge_transfer NSDictionary *)DMCopyHTTPRequestHeaders(hostBundle, NULL);
    if (devmateHeaders.count)
    {
        [request setAllHTTPHeaderFields:devmateHeaders];
    }
    
    if (NULL != hostBundle)
    {
        CFRelease(hostBundle);
    }
}

- (void)downloadUpdate
{
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[self.updateItem fileURL]];
    [request setValue:[self.updater userAgentString] forHTTPHeaderField:@"User-Agent"];
    [self updateURLRequestHTTPHeaders:request];
    if ([[self.updater delegate] respondsToSelector:@selector(updater:willDownloadUpdate:withRequest:)]) {
        [[self.updater delegate] updater:self.updater
                      willDownloadUpdate:self.updateItem
                             withRequest:request];
    }
    self.download = [[NSURLDownload alloc] initWithRequest:request delegate:self];
}

- (void)download:(NSURLDownload *)__unused d decideDestinationWithSuggestedFilename:(NSString *)name
{
    NSString *downloadFileName = [NSString stringWithFormat:@"%@ %@", [self.host name], [self.updateItem versionString]];


    self.tempDir = [self.host.appCachePath stringByAppendingPathComponent:downloadFileName];
    int cnt = 1;
	while ([[NSFileManager defaultManager] fileExistsAtPath:self.tempDir] && cnt <= 999)
	{
        self.tempDir = [self.host.appCachePath stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ %d", downloadFileName, cnt++]];
    }

    // Create the temporary directory if necessary.
    BOOL success = [[NSFileManager defaultManager] createDirectoryAtPath:self.tempDir withIntermediateDirectories:YES attributes:nil error:NULL];
	if (!success)
	{
        // Okay, something's really broken with this user's file structure.
        [self.download cancel];
        [self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SUTemporaryDirectoryError userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Can't make a temporary directory for the update download at %@.", self.tempDir] }]];
    }

    self.downloadPath = [self.tempDir stringByAppendingPathComponent:name];
    [self.download setDestination:self.downloadPath allowOverwrite:YES];
}

/**
 * If the update is a package, then it must be signed using DSA. No other verification is done.
 *
 * If the update is a bundle, then it must meet any one of:
 *
 *  * old and new DSA public keys are the same and valid (it allows change of Code Signing identity), or
 *
 *  * old and new Code Signing identity are the same and valid
 *
 */
- (BOOL)validateUpdateDownloadedToPath:(NSString *)downloadedPath extractedToPath:(NSString *)extractedPath DSASignature:(NSString *)DSASignature publicDSAKey:(NSString *)publicDSAKey
{
    BOOL isUpdateValid = NO;
    
    do
    {
        BOOL isPackage = NO;
        NSString *installSourcePath = [SUInstaller installSourcePathInUpdateFolder:extractedPath forHost:self.host isPackage:&isPackage isGuided:NULL];
        if (installSourcePath == nil)
        {
            SULog(@"No suitable install is found in the update. The update will be rejected.");
            break;
        }
    
        // Modern packages are not distributed as bundles and are code signed differently than regular applications
        if (isPackage)
        {
            isUpdateValid = [SUDSAVerifier validatePath:downloadedPath withEncodedDSASignature:DSASignature withPublicDSAKey:publicDSAKey];
            if (!isUpdateValid)
            {
                SULog(@"DSA signature validation of the package failed. The update will be rejected.");
            }
            
            break;
        }
    
        NSBundle *newBundle = [NSBundle bundleWithPath:installSourcePath];
        if (newBundle == nil)
        {
            SULog(@"No suitable bundle is found in the update. The update will be rejected.");
            break;
        }
    
        // Check Code Signing equality
        NSError *error = nil;
        BOOL updateIsCodeSigned = [SUCodeSigningVerifier applicationAtPathIsCodeSigned:installSourcePath];
        updateIsCodeSigned = updateIsCodeSigned && [SUCodeSigningVerifier codeSignatureIsValidAtPath:installSourcePath error:&error];
        if (!updateIsCodeSigned)
        {
            SULog(@"Update has no valid Code Signing (%ld - %@)", error.code, error.localizedDescription);
        }
        
        BOOL shouldCheckCodeSignEquality = updateIsCodeSigned ? [SUCodeSigningVerifier hostApplicationIsCodeSigned] : NO;
        if (shouldCheckCodeSignEquality && [SUCodeSigningVerifier codeSignatureMatchesHostAndIsValidAtPath:installSourcePath error:&error])
        {
            isUpdateValid = YES;
            break;
        }
        else
        {
            SULog(@"Code signatures differs in application and update (%ld - %@)", error.code, error.localizedDescription);
        }
    
        // Check DSA signature
        SUHost *newHost = [[SUHost alloc] initWithBundle:newBundle];
        NSString *newPublicDSAKey = newHost.publicDSAKey;
        
        BOOL dsaKeysMatch = (publicDSAKey == nil || newPublicDSAKey == nil) ? NO : [publicDSAKey isEqualToString:newPublicDSAKey];
        if (!dsaKeysMatch)
        {
            SULog(@"DSA keys are different for update and application.");
        }

        isUpdateValid = dsaKeysMatch && [SUDSAVerifier validatePath:downloadedPath withEncodedDSASignature:DSASignature withPublicDSAKey:newPublicDSAKey];
        if (!isUpdateValid)
        {
            SULog(@"DSA signature validation failed. The update has a public DSA key and is signed with a DSA key, but the %@ doesn't match the signature. The update will be rejected.", dsaKeysMatch ? @"public key" : @"new public key shipped with the update");
        }
    }
    while (NO);
    
    return isUpdateValid;
}

- (void)downloadDidFinish:(NSURLDownload *)__unused d
{
    assert(self.updateItem);

    [self extractUpdate];
}

- (void)download:(NSURLDownload *)__unused download didFailWithError:(NSError *)error
{
    NSURL *failingUrl = error.userInfo[NSURLErrorFailingURLErrorKey];
    if (!failingUrl) {
        failingUrl = [self.updateItem fileURL];
    }
    
    if ([[self.updater delegate] respondsToSelector:@selector(updater:failedToDownloadUpdate:error:)]) {
        [[self.updater delegate] updater:self.updater
                  failedToDownloadUpdate:self.updateItem
                                   error:error];
    }

    [self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SURelaunchError userInfo:@{
        NSLocalizedDescriptionKey: SULocalizedString(@"An error occurred while downloading the update. Please try again later.", nil),
        NSUnderlyingErrorKey: error,
        NSURLErrorFailingURLErrorKey: failingUrl ? failingUrl : [NSNull null],
    }]];
}

- (BOOL)download:(NSURLDownload *)__unused download shouldDecodeSourceDataOfMIMEType:(NSString *)encodingType
{
    // We don't want the download system to extract our gzips.
    // Note that we use a substring matching here instead of direct comparison because the docs say "application/gzip" but the system *uses* "application/x-gzip". This is a documentation bug.
    return ([encodingType rangeOfString:@"gzip"].location == NSNotFound);
}

- (void)extractUpdate
{
    SUUnarchiver *unarchiver = [SUUnarchiver unarchiverForPath:self.downloadPath updatingHostBundlePath:[[self.host bundle] bundlePath]];
    if (!unarchiver) {
        SULog(@"Error: No valid unarchiver for %@!", self.downloadPath);
        [self unarchiverDidFail:nil];
        return;
    }
    unarchiver.delegate = self;
    [unarchiver start];
}

- (void)failedToApplyDeltaUpdate
{
    // When a delta update fails to apply we fall back on updating via a full install.
    self.updateItem = self.nonDeltaUpdateItem;
    self.nonDeltaUpdateItem = nil;

    [self downloadUpdate];
}

- (void)unarchiverDidFinish:(SUUnarchiver *)__unused ua
{
    assert(self.updateItem);

    [self installWithToolAndRelaunch:YES];
}

- (void)unarchiverDidFail:(SUUnarchiver *)__unused ua
{
    if ([self.updateItem isDeltaUpdate]) {
        [self failedToApplyDeltaUpdate];
        return;
    }

    [self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SUUnarchivingError userInfo:@{ NSLocalizedDescriptionKey: SULocalizedString(@"An error occurred while extracting the archive. Please try again later.", nil) }]];
}

- (void)installWithToolAndRelaunch:(BOOL)relaunch
{
    // Perhaps a poor assumption but: if we're not relaunching, we assume we shouldn't be showing any UI either. Because non-relaunching installations are kicked off without any user interaction, we shouldn't be interrupting them.
    [self installWithToolAndRelaunch:relaunch displayingUserInterface:relaunch];
}

- (void)installWithToolAndRelaunch:(BOOL)relaunch displayingUserInterface:(BOOL)showUI
{
    assert(self.updateItem);

    if (![self validateUpdateDownloadedToPath:self.downloadPath extractedToPath:self.tempDir DSASignature:self.updateItem.DSASignature publicDSAKey:self.host.publicDSAKey])
    {
        NSDictionary *userInfo = @{
            NSLocalizedDescriptionKey: SULocalizedString(@"An error occurred while extracting the archive. Please try again later.", nil),
            NSLocalizedFailureReasonErrorKey: SULocalizedString(@"The update is improperly signed.", nil),
        };
        [self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SUSignatureError userInfo:userInfo]];
        return;
    }

    if (![self.updater mayUpdateAndRestart])
    {
        [self abortUpdate:SUUpdateAbortForbiddenByDelegate];
        return;
    }

    // Give the host app an opportunity to postpone the install and relaunch.
    static BOOL postponedOnce = NO;
    id<SUUpdaterDelegate> updaterDelegate = [self.updater delegate];
    if (!postponedOnce && [updaterDelegate respondsToSelector:@selector(updater:shouldPostponeRelaunchForUpdate:untilInvoking:)])
    {
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:[[self class] instanceMethodSignatureForSelector:@selector(installWithToolAndRelaunch:)]];
        [invocation setSelector:@selector(installWithToolAndRelaunch:)];
        [invocation setArgument:&relaunch atIndex:2];
        [invocation setTarget:self];
        postponedOnce = YES;
        if ([updaterDelegate updater:self.updater shouldPostponeRelaunchForUpdate:self.updateItem untilInvoking:invocation]) {
            return;
        }
    }


    if ([updaterDelegate respondsToSelector:@selector(updater:willInstallUpdate:)]) {
        [updaterDelegate updater:self.updater willInstallUpdate:self.updateItem];
    }

    NSBundle *sparkleBundle = self.updater.sparkleBundle;

    // Copy the relauncher into a temporary directory so we can get to it after the new version's installed.
    // Only the paranoid survive: if there's already a stray copy of relaunch there, we would have problems.
    NSString *const relaunchToolName = @"" SPARKLE_RELAUNCH_TOOL_NAME;
    NSString *const relaunchPathToCopy = [sparkleBundle pathForResource:relaunchToolName ofType:@"app"];
    if (relaunchPathToCopy != nil) {
        NSString *targetPath = [self.host.appCachePath stringByAppendingPathComponent:[relaunchPathToCopy lastPathComponent]];
        // Only the paranoid survive: if there's already a stray copy of relaunch there, we would have problems.
        NSError *error = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:[targetPath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:@{} error:&error];

        BOOL copySuccess = NO;
        if (SUShouldUseXPCInstaller())
        {
            copySuccess = [SUXPCInstaller copyPathWithAuthentication:relaunchPathToCopy overPath:targetPath appendVersion:SPARKLE_APPEND_VERSION_NUMBER error:&error];
        }
        else
        {
            copySuccess = [SUPlainInstaller copyPathWithAuthentication:relaunchPathToCopy overPath:targetPath appendVersion:SPARKLE_APPEND_VERSION_NUMBER error:&error];
        }
        if (copySuccess) {
            self.relaunchPath = targetPath;
        } else {
            [self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SURelaunchError userInfo:@{
                NSLocalizedDescriptionKey: SULocalizedString(@"An error occurred while extracting the archive. Please try again later.", nil),
                NSLocalizedFailureReasonErrorKey: [NSString stringWithFormat:@"Couldn't copy relauncher (%@) to temporary path (%@)! %@", relaunchPathToCopy, targetPath, (error ? [error localizedDescription] : @"")]
            }]];
        }
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:SUUpdaterWillRestartNotification object:self];
    if ([updaterDelegate respondsToSelector:@selector(updaterWillRelaunchApplication:)])
        [updaterDelegate updaterWillRelaunchApplication:self.updater];

    NSString *relaunchToolPath = [[NSBundle bundleWithPath:self.relaunchPath] executablePath];
    if (!relaunchToolPath || ![[NSFileManager defaultManager] fileExistsAtPath:self.relaunchPath]) {
        // Note that we explicitly use the host app's name here, since updating plugin for Mail relaunches Mail, not just the plugin.
        [self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SURelaunchError userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:SULocalizedString(@"An error occurred while relaunching %1$@, but the new version will be available next time you run %1$@.", nil), [self.host name]],
            NSLocalizedFailureReasonErrorKey: [NSString stringWithFormat:@"Couldn't find the relauncher (expected to find it at %@)", self.relaunchPath]
        }]];
        // We intentionally don't abandon the update here so that the host won't initiate another.
        return;
    }

    NSString *pathToRelaunch = [self.host bundlePath];
    if ([updaterDelegate respondsToSelector:@selector(pathToRelaunchForUpdater:)]) {
        pathToRelaunch = [updaterDelegate pathToRelaunchForUpdater:self.updater];
    }
    NSArray *arguments = @[[self.host bundlePath],
                           pathToRelaunch,
                           [NSString stringWithFormat:@"%d", [[NSProcessInfo processInfo] processIdentifier]],
                           self.tempDir,
                           relaunch ? @"1" : @"0",
                           showUI ? @"1" : @"0"];
    if (SUShouldUseXPCInstaller())
    {
        [SUXPCInstaller launchTaskWithPath:relaunchToolPath arguments:arguments environment:nil currentDirectoryPath:nil inputData:nil waitForTaskResult:NO waitUntilDone:NO completionHandler:nil];
    }
    else
    {
        [NSTask launchedTaskWithLaunchPath:relaunchToolPath arguments:arguments];
    }
    [self terminateApp];
}

- (void)terminateApp
{
    [NSApp terminate:self];
}

- (void)cleanUpDownload
{
    if (self.tempDir != nil) // tempDir contains downloadPath, so we implicitly delete both here.
    {
        BOOL success = NO;
        NSError *error = nil;
        success = [[NSFileManager defaultManager] removeItemAtPath:self.tempDir error:&error]; // Clean up the copied relauncher
        if (!success)
            [[NSWorkspace sharedWorkspace] performFileOperation:NSWorkspaceRecycleOperation source:[self.tempDir stringByDeletingLastPathComponent] destination:@"" files:@[[self.tempDir lastPathComponent]] tag:NULL];
    }
}

- (void)installerForHost:(SUHost *)aHost failedWithError:(NSError *)error
{
    if (aHost != self.host) {
        return;
    }
    NSError *dontThrow = nil;
    [[NSFileManager defaultManager] removeItemAtPath:self.relaunchPath error:&dontThrow]; // Clean up the copied relauncher
    [self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SUInstallationError userInfo:@{
        NSLocalizedDescriptionKey: SULocalizedString(@"An error occurred while installing the update. Please try again later.", nil),
        NSLocalizedFailureReasonErrorKey: [error localizedDescription],
        NSUnderlyingErrorKey: error,
    }]];
}

- (void)abortUpdate:(SUUpdateAbortReason)reason
{
    [self cleanUpDownload];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    self.updateItem = nil;
    [super abortUpdate:reason];
}

- (void)abortUpdateWithError:(NSError *)error
{
    if ([error code] != SUNoUpdateError) { // Let's not bother logging this.
        SULog(@"Error: %@ %@ (URL %@)", error.localizedDescription, error.localizedFailureReason, error.userInfo[NSURLErrorFailingURLErrorKey]);
    }
    if (self.download) {
        [self.download cancel];
    }

    // Notify host app that update has aborted
    id<SUUpdaterDelegate> updaterDelegate = [self.updater delegate];
    if ([updaterDelegate respondsToSelector:@selector(updater:didAbortWithError:)]) {
        [updaterDelegate updater:self.updater didAbortWithError:error];
    }

    [self abortUpdate:SUUpdateAbortGotError];
}

@end
