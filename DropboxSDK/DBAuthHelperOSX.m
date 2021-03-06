//
//  DBAuthHelperOSX.m
//  DropboxSDK
//
//  Created by Brian Smith on 3/26/12.
//  Copyright (c) 2012 Dropbox, Inc. All rights reserved.
//

#import "DBAuthHelperOSX.h"

#import "DBLog.h"

NSString *DBAuthHelperOSXStateChangedNotification = @"DBAuthHelperOSXStateChangedNotification";


@interface DBAuthHelperOSX () <DBRestClientOSXDelegate>

- (void)postStateChangedNotification;

@property (nonatomic, readonly) DBRestClient *restClient;
@property BOOL waitingForAccess;

@end


@implementation DBAuthHelperOSX

@synthesize loading;

+ (DBAuthHelperOSX *)sharedHelper {
	static DBAuthHelperOSX *sharedHelper;
	if (!sharedHelper) {
		sharedHelper = [DBAuthHelperOSX new];
	}

	return sharedHelper;
}

- (id)init {
	if ((self = [super init])) {
	}
	return self;
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}


#pragma mark public methods

- (void)authenticate {
	if (loading) {
		DBLogError(@"DropboxSDK: called -[DBAuthHelperOSX authenticate] while the auth helper is already loading. Doing nothing.");
		return;
	} else if ([[DBSession sharedSession] isLinked]) {
		DBLogError(@"DropboxSDK: called -[DBAuthHelperOSX authenticate] when already linked. Doing nothing.");
		return;
	}

	loading = YES;
	[self postStateChangedNotification];

	[self.restClient loadRequestToken];
}


#pragma mark DBRestClientOSXDelegate methods

- (void)restClientLoadedRequestToken:(DBRestClient *)restClient {
    loading = NO;

	[self postStateChangedNotification];

	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive:) name:NSApplicationDidBecomeActiveNotification object:nil];

    NSURL *url = [self.restClient authorizeURL];
    [[NSWorkspace sharedWorkspace] openURL:url];
    
    self.waitingForAccess = YES;
    [self waitForAccess];
}

- (void)restClient:(DBRestClient *)restClient loadRequestTokenFailedWithError:(NSError *)error {
	loading = NO;
	if (![self.restClient requestTokenLoaded]) {
		[[NSNotificationCenter defaultCenter] removeObserver:self];
	}
	[self postStateChangedNotification];
}

- (void)restClientLoadedAccessToken:(DBRestClient *)client {
    NSLog(@"Dropbox Access Granted");
    
	loading = NO;
    self.waitingForAccess = NO;
    
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	
    restClient = nil;
	[self postStateChangedNotification];
}

- (void)restClient:(DBRestClient *)restClient loadAccessTokenFailedWithError:(NSError *)error {
    loading = NO;

	[self postStateChangedNotification];
}


#pragma mark private methods

- (void)postStateChangedNotification {
	[[NSNotificationCenter defaultCenter] postNotificationName:DBAuthHelperOSXStateChangedNotification object:self];
}

- (DBRestClient *)restClient {
	if (!restClient) {
		restClient = [[DBRestClient alloc] initWithSession:[DBSession sharedSession]];
		restClient.delegate = self;
	}
	return restClient;
}

- (void)applicationDidBecomeActive:(NSNotification*)notification {
	if ([self.restClient requestTokenLoaded] && !loading) {
		[self postStateChangedNotification];

		[self.restClient loadAccessToken];
	}
}

- (void)waitForAccess {
    while (self.waitingForAccess)
    {
        NSLog(@"Waiting for Dropbox Access");
        
        if ([self.restClient requestTokenLoaded] && !loading) {
            [self.restClient loadAccessToken];
        }
        
        [NSThread sleepForTimeInterval:10.0];
    }
}

@end
