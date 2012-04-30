//
//  DBRestClient.m
//  DropboxSDK
//
//  Created by Brian Smith on 4/9/10.
//  Copyright 2010 Dropbox, Inc. All rights reserved.
//
//	March 2012. Roustem Karimov. Added NSOperationQueue for DBRequests

#import "DBRestClient.h"

#import "DBDeltaEntry.h"
#import "DBAccountInfo.h"
#import "DBError.h"
#import "DBLog.h"
#import "DBMetadata.h"
#import "DBRequest.h"
#import "MPOAuthURLRequest.h"
#import "MPURLRequestParameter.h"
#import "MPOAuthSignatureParameter.h"
#import "NSString+URLEscapingAdditions.h"


@interface DBRestClient () {
	DBSession* session;
	NSString* userId;
	NSString* root;

	NSMutableSet* requests;
	
	/* Map from path to the load request. Needs to be expanded to a general framework for cancelling
	 requests. */
	NSMutableDictionary* loadRequests;
	NSMutableDictionary* imageLoadRequests;
	NSMutableDictionary* uploadRequests;
	__weak id<DBRestClientDelegate> delegate;
	
	NSOperationQueue *requestQueue;
}

	// This method escapes all URI escape characters except /
+ (NSString *)escapePath:(NSString*)path;
+ (NSString *)bestLanguage;
+ (NSString *)userAgent;

- (NSMutableURLRequest*)requestWithHost:(NSString*)host path:(NSString*)path parameters:(NSDictionary*)params;
- (NSMutableURLRequest*)requestWithHost:(NSString*)host path:(NSString*)path parameters:(NSDictionary*)params method:(NSString*)method;
- (void)checkForAuthenticationFailure:(DBRequest*)request;

@property (nonatomic, readonly) MPOAuthCredentialConcreteStore *credentialStore;

@end


@implementation DBRestClient

@synthesize delegate;

- (id)initWithSession:(DBSession*)aSession userId:(NSString *)theUserId {
    if (!aSession) {
        DBLogError(@"DropboxSDK: cannot initialize a DBRestClient with a nil session");
        return nil;
    }
	
    if ((self = [super init])) {
        session = aSession;
        userId = theUserId;
        root = aSession.root;
        
		requests = [[NSMutableSet alloc] init];
        loadRequests = [[NSMutableDictionary alloc] init];
        imageLoadRequests = [[NSMutableDictionary alloc] init];
        uploadRequests = [[NSMutableDictionary alloc] init];
		
		requestQueue = [[NSOperationQueue alloc] init];
		requestQueue.name = @"dropbox-request-queue";
		requestQueue.maxConcurrentOperationCount = 8;
    }
    return self;
}

- (id)initWithSession:(DBSession *)aSession {
    NSString *uid = [aSession.userIds count] > 0 ? [aSession.userIds objectAtIndex:0] : nil;
    return [self initWithSession:aSession userId:uid];
}


- (void)cancelAllRequests {
	@synchronized (requests) {
		for (DBRequest* request in requests) [request cancel];
		[requests removeAllObjects];
	}
	
	@synchronized (loadRequests) {
		for (DBRequest* request in [loadRequests allValues]) [request cancel];
		[loadRequests removeAllObjects];
	}
	
	@synchronized (imageLoadRequests) {
		for (DBRequest* request in [imageLoadRequests allValues]) [request cancel];
		[imageLoadRequests removeAllObjects];
	}
	
	@synchronized (uploadRequests) {
		for (DBRequest* request in [uploadRequests allValues]) [request cancel];
		[uploadRequests removeAllObjects];
	}
}


- (void)dealloc {
	[self cancelAllRequests];
}

- (NSInteger)maxConcurrentConnectionCount {
	return requestQueue.maxConcurrentOperationCount;
}

- (void)setMaxConcurrentConnectionCount:(NSInteger)maxConcurrentConnectionCount {
	requestQueue.maxConcurrentOperationCount = maxConcurrentConnectionCount;
}

- (DBRequest *)requestWithURLRequest:(NSURLRequest *)urlRequest selector:(SEL)selector {
    DBRequest* request = [[DBRequest alloc] initWithURLRequest:urlRequest andInformTarget:self selector:selector];
	[requestQueue addOperation:request];
	
	return request;
}


- (void)loadMetadata:(NSString*)path withParams:(NSDictionary *)params {
    NSString* fullPath = [NSString stringWithFormat:@"/metadata/%@%@", root, path];
    NSURLRequest* urlRequest = [self requestWithHost:kDBDropboxAPIHost path:fullPath parameters:params];
    
    DBRequest* request = [self requestWithURLRequest:urlRequest selector:@selector(requestDidLoadMetadata:)];
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObject:path forKey:@"path"];
    if (params) {
        [userInfo addEntriesFromDictionary:params];
    }
    request.userInfo = userInfo;
	
	@synchronized (requests) {
		[requests addObject:request];
	}
}

- (void)loadMetadata:(NSString*)path {
    [self loadMetadata:path withParams:nil];
}

- (void)loadMetadata:(NSString*)path withHash:(NSString*)hash {
    NSDictionary *params = (hash ? [NSDictionary dictionaryWithObject:hash forKey:@"hash"] : nil);
    [self loadMetadata:path withParams:params];
}

- (void)loadMetadata:(NSString *)path atRev:(NSString *)rev {
    NSDictionary *params = (rev ? [NSDictionary dictionaryWithObject:rev forKey:@"rev"] : nil);
    [self loadMetadata:path withParams:params];
}

- (void)requestDidLoadMetadata:(DBRequest *)request {
    if (request.statusCode == 304) {
        if ([delegate respondsToSelector:@selector(restClient:metadataUnchangedAtPath:)]) {
            NSString* path = [request.userInfo objectForKey:@"path"];
            [delegate restClient:self metadataUnchangedAtPath:path];
        }
    } 
	else if (request.error) {
        [self checkForAuthenticationFailure:request];
        if ([delegate respondsToSelector:@selector(restClient:loadMetadataFailedWithError:)]) {
            [delegate restClient:self loadMetadataFailedWithError:request.error];
        }
    } 
	else {
		NSDictionary* result = (NSDictionary*)[request resultJSON];
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
			DBMetadata* metadata = [[DBMetadata alloc] initWithDictionary:result];
			if (metadata) {
				if ([delegate respondsToSelector:@selector(restClient:loadedMetadata:)]) {
					[delegate restClient:self loadedMetadata:metadata];
				}
			} else {
				NSError *error = [NSError errorWithDomain:DBErrorDomain code:DBErrorInvalidResponse userInfo:request.userInfo];
				DBLogWarning(@"DropboxSDK: error parsing metadata");
				if ([delegate respondsToSelector:@selector(restClient:loadMetadataFailedWithError:)]) {
					[delegate restClient:self loadMetadataFailedWithError:error];
				}
			}
        });
    }
	
	@synchronized (requests) {
		[requests removeObject:request];
	}
}


- (void)loadDelta:(NSString *)cursor {
    NSDictionary *params = nil;
    if (cursor) {
        params = [NSDictionary dictionaryWithObject:cursor forKey:@"cursor"];
    }
	
    NSString *fullPath = [NSString stringWithFormat:@"/delta"];
    NSMutableURLRequest* urlRequest =
	[self requestWithHost:kDBDropboxAPIHost path:fullPath parameters:params method:@"POST"];
	
    DBRequest* request = [[DBRequest alloc] initWithURLRequest:urlRequest andInformTarget:self selector:@selector(requestDidLoadDelta:)];
	
    request.userInfo = params;
    [requests addObject:request];
}

- (void)requestDidLoadDelta:(DBRequest *)request {
    if (request.error) {
        [self checkForAuthenticationFailure:request];
        if ([delegate respondsToSelector:@selector(restClient:loadDeltaFailedWithError:)]) {
            [delegate restClient:self loadDeltaFailedWithError:request.error];
        }
    } 
	else {
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
			NSDictionary* result = [request parseResponseAsType:[NSDictionary class]];
			if (result) {
				NSArray *entryArrays = [result objectForKey:@"entries"];
				NSMutableArray *entries = [NSMutableArray arrayWithCapacity:[entryArrays count]];
				for (NSArray *entryArray in entryArrays) {
					DBDeltaEntry *entry = [[DBDeltaEntry alloc] initWithArray:entryArray];
					[entries addObject:entry];
				}
				BOOL reset = [[result objectForKey:@"reset"] boolValue];
				NSString *cursor = [result objectForKey:@"cursor"];
				BOOL hasMore = [[result objectForKey:@"has_more"] boolValue];
				
				if ([delegate respondsToSelector:@selector(restClient:loadedDeltaEntries:reset:cursor:hasMore:)]) {
					[delegate restClient:self loadedDeltaEntries:entryArrays reset:reset cursor:cursor hasMore:hasMore];
				}
			} 
			else {
				NSError *error = [NSError errorWithDomain:DBErrorDomain code:DBErrorInvalidResponse userInfo:request.userInfo];
				DBLogWarning(@"DropboxSDK: error parsing metadata");
				if ([delegate respondsToSelector:@selector(restClient:loadDeltaFailedWithError:)]) {
					[delegate restClient:self loadDeltaFailedWithError:error];
				}
			}
		});
    }
	
    [requests removeObject:request];
}

- (void)loadFile:(NSString *)path atRev:(NSString *)rev intoPath:(NSString *)destPath
{
    NSString* fullPath = [NSString stringWithFormat:@"/files/%@%@", root, path];
	
    NSDictionary *params = nil;
    if (rev) {
        params = [NSDictionary dictionaryWithObject:rev forKey:@"rev"];
    }
    
    NSURLRequest* urlRequest = [self requestWithHost:kDBDropboxAPIContentHost path:fullPath parameters:params];
    DBRequest* request = [self requestWithURLRequest:urlRequest selector:@selector(requestDidLoadFile:)];
    request.resultFilename = destPath;
    request.downloadProgressSelector = @selector(requestLoadProgress:);
    request.userInfo = [NSDictionary dictionaryWithObjectsAndKeys:
						path, @"path", 
						destPath, @"destinationPath", 
						rev, @"rev", nil];

    
	@synchronized (loadRequests) {
		[loadRequests setObject:request forKey:path];
	}
}

- (void)loadFile:(NSString *)path intoPath:(NSString *)destPath {
    [self loadFile:path atRev:nil intoPath:destPath];
}

- (void)cancelFileLoad:(NSString*)path {
	@synchronized (loadRequests) {
		DBRequest* outstandingRequest = [loadRequests objectForKey:path];
		if (outstandingRequest) {
			[outstandingRequest cancel];
			[loadRequests removeObjectForKey:path];
		}
	}
}


- (void)requestLoadProgress:(DBRequest*)request {
    if ([delegate respondsToSelector:@selector(restClient:loadProgress:forFile:)]) {
        [delegate restClient:self loadProgress:request.downloadProgress forFile:[request.resultFilename copy]];
    }
}


- (void)restClient:(DBRestClient*)restClient loadedFile:(NSString*)destPath contentType:(NSString*)contentType eTag:(NSString*)eTag {
		// Empty selector to get the signature from
}

- (void)requestDidLoadFile:(DBRequest *)request {
    NSString* path = [[request.userInfo objectForKey:@"path"] copy];
	
    if (request.error) {
        [self checkForAuthenticationFailure:request];
        if ([delegate respondsToSelector:@selector(restClient:loadFileFailedWithError:)]) {
            [delegate restClient:self loadFileFailedWithError:request.error];
        }
    } 
	else {
        NSString* filename = [request.resultFilename copy];
        NSDictionary* headers = [[request.response allHeaderFields] copy];
		NSString* contentType = [[headers objectForKey:@"Content-Type"] copy];
        NSDictionary* metadataDict = [[request xDropboxMetadataJSON] copy];
        NSString* eTag = [[headers objectForKey:@"Etag"] copy];
		DBRestClient *myself = self;
		
        if ([delegate respondsToSelector:@selector(restClient:loadedFile:)]) {
            [delegate restClient:self loadedFile:filename];
        } 
		else if ([delegate respondsToSelector:@selector(restClient:loadedFile:contentType:metadata:)]) {
            DBMetadata* metadata = [[DBMetadata alloc] initWithDictionary:metadataDict];
            [delegate restClient:self loadedFile:filename contentType:contentType metadata:metadata];
        } 
		else if ([delegate respondsToSelector:@selector(restClient:loadedFile:contentType:)]) {
				// This callback is deprecated and this block exists only for backwards compatibility.
            [delegate restClient:self loadedFile:filename contentType:contentType];
        } 
		else if ([delegate respondsToSelector:@selector(restClient:loadedFile:contentType:eTag:)]) {
				// This code is for the official Dropbox client to get eTag information from the server
            NSMethodSignature* signature = [self methodSignatureForSelector:@selector(restClient:loadedFile:contentType:eTag:)];
            NSInvocation* invocation = [NSInvocation invocationWithMethodSignature:signature];
			
            [invocation setTarget:delegate];
            [invocation setSelector:@selector(restClient:loadedFile:contentType:eTag:)];
            [invocation setArgument:&myself atIndex:2];
            [invocation setArgument:&filename atIndex:3];
            [invocation setArgument:&contentType atIndex:4];
            [invocation setArgument:&eTag atIndex:5];
            [invocation invoke];
        }
    }

	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
		@synchronized (loadRequests) {
			[loadRequests removeObjectForKey:path];
		}
	});
}


- (NSString*)thumbnailKeyForPath:(NSString*)path size:(NSString*)size {
    return [NSString stringWithFormat:@"%@##%@", path, size];
}


- (void)loadThumbnail:(NSString *)path ofSize:(NSString *)size intoPath:(NSString *)destinationPath {
    NSString* fullPath = [NSString stringWithFormat:@"/thumbnails/%@%@", root, path];
    
    NSString* format = @"JPEG";
    if ([path length] > 4) {
        NSString* extension = [[path substringFromIndex:[path length] - 4] uppercaseString];
        if ([[NSSet setWithObjects:@".PNG", @".GIF", nil] containsObject:extension]) {
            format = @"PNG";
        }
    }
    
    NSMutableDictionary* params = [NSMutableDictionary dictionaryWithObject:format forKey:@"format"];
    if(size) {
        [params setObject:size forKey:@"size"];
    }
    
    NSURLRequest* urlRequest = [self requestWithHost:kDBDropboxAPIContentHost path:fullPath parameters:params];
	
    DBRequest* request = [self requestWithURLRequest:urlRequest selector:@selector(requestDidLoadThumbnail:)];
	
    request.resultFilename = destinationPath;
    request.userInfo = [NSDictionary dictionaryWithObjectsAndKeys:
						root, @"root", 
						path, @"path", 
						destinationPath, @"destinationPath", 
						size, @"size", nil];
	
	@synchronized (imageLoadRequests) {
		[imageLoadRequests setObject:request forKey:[self thumbnailKeyForPath:path size:size]];
	}
}

- (void)requestDidLoadThumbnail:(DBRequest*)request
{
    if (request.error) {
        [self checkForAuthenticationFailure:request];
        if ([delegate respondsToSelector:@selector(restClient:loadThumbnailFailedWithError:)]) {
            [delegate restClient:self loadThumbnailFailedWithError:request.error];
        }
    } else {
        NSString* filename = request.resultFilename;
        NSDictionary* metadataDict = [request xDropboxMetadataJSON];
        if ([delegate respondsToSelector:@selector(restClient:loadedThumbnail:metadata:)]) {
            DBMetadata* metadata = [[DBMetadata alloc] initWithDictionary:metadataDict];
            [delegate restClient:self loadedThumbnail:filename metadata:metadata];
        } else if ([delegate respondsToSelector:@selector(restClient:loadedThumbnail:)]) {
				// This callback is deprecated and this block exists only for backwards compatibility.
            [delegate restClient:self loadedThumbnail:filename];
        }
    }
	
    NSString* path = [request.userInfo objectForKey:@"path"];
    NSString* size = [request.userInfo objectForKey:@"size"];
	@synchronized (imageLoadRequests) {
		[imageLoadRequests removeObjectForKey:[self thumbnailKeyForPath:path size:size]];
	}
}


- (void)cancelThumbnailLoad:(NSString*)path size:(NSString*)size {
    NSString* key = [self thumbnailKeyForPath:path size:size];
	@synchronized (imageLoadRequests) {
		DBRequest* request = [imageLoadRequests objectForKey:key];
		if (request) {
			[request cancel];
			[imageLoadRequests removeObjectForKey:key];
		}
	}
}

- (NSString *)signatureForParams:(NSArray *)params url:(NSURL *)baseUrl {
    NSMutableArray* paramList = [NSMutableArray arrayWithArray:params];
    [paramList sortUsingSelector:@selector(compare:)];
    NSString* paramString = [MPURLRequestParameter parameterStringForParameters:paramList];
    
    MPOAuthURLRequest* oauthRequest = 
	[[MPOAuthURLRequest alloc] initWithURL:baseUrl andParameters:paramList];
    oauthRequest.HTTPMethod = @"POST";
    MPOAuthSignatureParameter *signatureParameter = 
	[[MPOAuthSignatureParameter alloc] 
	  initWithText:paramString andSecret:self.credentialStore.signingKey 
	  forRequest:oauthRequest usingMethod:self.credentialStore.signatureMethod];
	
    return [signatureParameter URLEncodedParameterString];
}

- (NSMutableURLRequest *)requestForParams:(NSArray *)params urlString:(NSString *)urlString signature:(NSString *)sig {
	
    NSMutableArray *paramList = [NSMutableArray arrayWithArray:params];
		// Then rebuild request using that signature
    [paramList sortUsingSelector:@selector(compare:)];
    NSMutableString* realParamString = [[NSMutableString alloc] initWithString:
										 [MPURLRequestParameter parameterStringForParameters:paramList]];
    [realParamString appendFormat:@"&%@", sig];
    
    NSURL* url = [NSURL URLWithString:[NSString stringWithFormat:@"%@?%@", urlString, realParamString]];
    NSMutableURLRequest* urlRequest = [NSMutableURLRequest requestWithURL:url];
    urlRequest.HTTPMethod = @"POST";
	
    return urlRequest;
}

- (void)uploadFile:(NSString*)filename toPath:(NSString*)path fromPath:(NSString *)sourcePath
			params:(NSDictionary *)params
{
    BOOL isDir = NO;
    BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:sourcePath isDirectory:&isDir];
    NSDictionary *fileAttrs = 
	[[NSFileManager defaultManager] attributesOfItemAtPath:sourcePath error:nil];
	
    if (!fileExists || isDir || !fileAttrs) {
        NSString* destPath = [path stringByAppendingPathComponent:filename];
        NSDictionary* userInfo = [NSDictionary dictionaryWithObjectsAndKeys:
								  sourcePath, @"sourcePath",
								  destPath, @"destinationPath", nil];
        NSInteger errorCode = isDir ? DBErrorIllegalFileType : DBErrorFileNotFound;
        NSError* error = 
		[NSError errorWithDomain:DBErrorDomain code:errorCode userInfo:userInfo];
        NSString *errorMsg = isDir ? @"Unable to upload folders" : @"File does not exist";
        DBLogWarning(@"DropboxSDK: %@ (%@)", errorMsg, sourcePath);
        if ([delegate respondsToSelector:@selector(restClient:uploadFileFailedWithError:)]) {
            [delegate restClient:self uploadFileFailedWithError:error];
        }
        return;
    }
	
    NSString *destPath = [path stringByAppendingPathComponent:filename];
    NSString *urlString = [NSString stringWithFormat:@"%@://%@/%@/files_put/%@%@", kDBProtocolHTTPS, kDBDropboxAPIContentHost, kDBDropboxAPIVersion, root, [DBRestClient escapePath:destPath]];
    
    NSArray *extraParams = [MPURLRequestParameter parametersFromDictionary:params];
    NSArray *paramList = [[self.credentialStore oauthParameters] arrayByAddingObjectsFromArray:extraParams];
    NSString *sig = [self signatureForParams:paramList url:[NSURL URLWithString:urlString]];
    NSMutableURLRequest *urlRequest = [self requestForParams:paramList urlString:urlString signature:sig];
    
    NSString* contentLength = [NSString stringWithFormat: @"%qu", [fileAttrs fileSize]];
    [urlRequest addValue:contentLength forHTTPHeaderField: @"Content-Length"];
    [urlRequest addValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];
    
    [urlRequest setHTTPBodyStream:[NSInputStream inputStreamWithFileAtPath:sourcePath]];
    
    DBRequest *request = [self requestWithURLRequest:urlRequest selector:@selector(requestDidUploadFile:)];
    request.uploadProgressSelector = @selector(requestUploadProgress:);
    request.userInfo = 
	[NSDictionary dictionaryWithObjectsAndKeys:sourcePath, @"sourcePath", destPath, @"destinationPath", nil];
    
	@synchronized (uploadRequests) {
		[uploadRequests setObject:request forKey:destPath];
	}
}

- (void)uploadFile:(NSString*)filename toPath:(NSString*)path fromPath:(NSString *)sourcePath
{
    [self uploadFile:filename toPath:path fromPath:sourcePath params:nil];
}

- (void)uploadFile:(NSString *)filename toPath:(NSString *)path withParentRev:(NSString *)parentRev
		  fromPath:(NSString *)sourcePath {
	
    NSMutableDictionary *params = [NSMutableDictionary dictionaryWithObject:@"false" forKey:@"overwrite"];
    if (parentRev) {
        [params setObject:parentRev forKey:@"parent_rev"];
    }
    [self uploadFile:filename toPath:path fromPath:sourcePath params:params];
}


- (void)requestUploadProgress:(DBRequest*)request {
    NSString* sourcePath = [(NSDictionary*)request.userInfo objectForKey:@"sourcePath"];
    NSString* destPath = [request.userInfo objectForKey:@"destinationPath"];
	
    if ([delegate respondsToSelector:@selector(restClient:uploadProgress:forFile:from:)]) {
        [delegate restClient:self uploadProgress:request.uploadProgress
					 forFile:destPath from:sourcePath];
    }
}


- (void)requestDidUploadFile:(DBRequest*)request {
    NSDictionary *result = [request parseResponseAsType:[NSDictionary class]];
	
    if (!result) {
        [self checkForAuthenticationFailure:request];
        if ([delegate respondsToSelector:@selector(restClient:uploadFileFailedWithError:)]) {
            [delegate restClient:self uploadFileFailedWithError:request.error];
        }
    } 
	else {
        DBMetadata *metadata = [[DBMetadata alloc] initWithDictionary:result];
		
        NSString* sourcePath = [request.userInfo objectForKey:@"sourcePath"];
        NSString* destPath = [request.userInfo objectForKey:@"destinationPath"];
        
        if ([delegate respondsToSelector:@selector(restClient:uploadedFile:from:metadata:)]) {
            [delegate restClient:self uploadedFile:destPath from:sourcePath metadata:metadata];
        } else if ([delegate respondsToSelector:@selector(restClient:uploadedFile:from:)]) {
            [delegate restClient:self uploadedFile:destPath from:sourcePath];
        }
    }
	
	@synchronized (uploadRequests) {
		[uploadRequests removeObjectForKey:[request.userInfo objectForKey:@"destinationPath"]];
	}
}

- (void)cancelFileUpload:(NSString *)path {
	@synchronized (uploadRequests) {
		DBRequest *request = [uploadRequests objectForKey:path];
		if (request) {
			[request cancel];
			[uploadRequests removeObjectForKey:path];
		}
	}
}


- (void)loadRevisionsForFile:(NSString *)path {
    [self loadRevisionsForFile:path limit:10];
}

- (void)loadRevisionsForFile:(NSString *)path limit:(NSInteger)limit {
    NSString *fullPath = [NSString stringWithFormat:@"/revisions/%@%@", root, path];
    NSString *limitStr = [NSString stringWithFormat:@"%d", limit];
    NSDictionary *params = [NSDictionary dictionaryWithObject:limitStr forKey:@"rev_limit"];
    NSURLRequest* urlRequest = [self requestWithHost:kDBDropboxAPIHost path:fullPath parameters:params];
    
    DBRequest* request = [self requestWithURLRequest:urlRequest selector:@selector(requestDidLoadRevisions:)];
    request.userInfo = [NSDictionary dictionaryWithObjectsAndKeys:
						path, @"path",
						[NSNumber numberWithInt:limit], @"limit", nil];
	
	@synchronized (requests) {
		[requests addObject:request];
	}
}

- (void)requestDidLoadRevisions:(DBRequest *)request {
    NSArray *resp = [request parseResponseAsType:[NSArray class]];
    
    if (!resp) {
        if ([delegate respondsToSelector:@selector(restClient:loadRevisionsFailedWithError:)]) {
            [delegate restClient:self loadRevisionsFailedWithError:request.error];
        }
    } else {
        NSMutableArray *revisions = [NSMutableArray arrayWithCapacity:[resp count]];
        for (NSDictionary *dict in resp) {
            DBMetadata *metadata = [[DBMetadata alloc] initWithDictionary:dict];
            [revisions addObject:metadata];
        }
        NSString *path = [request.userInfo objectForKey:@"path"];
		
        if ([delegate respondsToSelector:@selector(restClient:loadedRevisions:forFile:)]) {
            [delegate restClient:self loadedRevisions:revisions forFile:path];
        }
    }
}

- (void)restoreFile:(NSString *)path toRev:(NSString *)rev {
    NSString *fullPath = [NSString stringWithFormat:@"/restore/%@%@", root, path];
    NSDictionary *params = [NSDictionary dictionaryWithObject:rev forKey:@"rev"];
    NSURLRequest* urlRequest = [self requestWithHost:kDBDropboxAPIHost path:fullPath parameters:params];
    
    DBRequest* request = [self requestWithURLRequest:urlRequest selector:@selector(requestDidRestoreFile:)];
    request.userInfo = [NSDictionary dictionaryWithObjectsAndKeys:
						path, @"path",
						rev, @"rev", nil];
	
	@synchronized (requests) {
		[requests addObject:request];
	}
}

- (void)requestDidRestoreFile:(DBRequest *)request {
    NSDictionary *dict = [request parseResponseAsType:[NSDictionary class]];
	
    if (!dict) {
        if ([delegate respondsToSelector:@selector(restClient:restoreFileFailedWithError:)]) {
            [delegate restClient:self restoreFileFailedWithError:request.error];
        }
    } else {
        DBMetadata *metadata = [[DBMetadata alloc] initWithDictionary:dict];
        if ([delegate respondsToSelector:@selector(restClient:restoredFile:)]) {
            [delegate restClient:self restoredFile:metadata];
        }
    }
}


- (void)moveFrom:(NSString*)from_path toPath:(NSString *)to_path
{
    NSDictionary* params = [NSDictionary dictionaryWithObjectsAndKeys:
							root, @"root",
							from_path, @"from_path",
							to_path, @"to_path", nil];
	
    NSMutableURLRequest* urlRequest = [self requestWithHost:kDBDropboxAPIHost path:@"/fileops/move" parameters:params method:@"POST"];
	
    DBRequest* request = [self requestWithURLRequest:urlRequest selector:@selector(requestDidMovePath:)];
    request.userInfo = params;

	@synchronized (requests) {
		[requests addObject:request];
	}
}



- (void)requestDidMovePath:(DBRequest*)request {
    if (request.error) {
        [self checkForAuthenticationFailure:request];
        if ([delegate respondsToSelector:@selector(restClient:movePathFailedWithError:)]) {
            [delegate restClient:self movePathFailedWithError:request.error];
        }
    } 
	else {
        NSDictionary *params = (NSDictionary *)request.userInfo;
		
        if ([delegate respondsToSelector:@selector(restClient:movedPath:toPath:)]) {
            [delegate restClient:self movedPath:[params valueForKey:@"from_path"] toPath:[params valueForKey:@"to_path"]];
        }
    }
	
	@synchronized (requests) {
		[requests removeObject:request];
	}
}


- (void)copyFrom:(NSString*)from_path toPath:(NSString *)to_path
{
    NSDictionary* params = [NSDictionary dictionaryWithObjectsAndKeys:
							root, @"root",
							from_path, @"from_path",
							to_path, @"to_path", nil];
	
    NSMutableURLRequest* urlRequest = [self requestWithHost:kDBDropboxAPIHost path:@"/fileops/copy" parameters:params method:@"POST"];
	
    DBRequest* request = [self requestWithURLRequest:urlRequest selector:@selector(requestDidCopyPath:)];
    request.userInfo = params;

	@synchronized (requests) {
		[requests addObject:request];
	}
}



- (void)requestDidCopyPath:(DBRequest*)request {
    if (request.error) {
        [self checkForAuthenticationFailure:request];
        if ([delegate respondsToSelector:@selector(restClient:copyPathFailedWithError:)]) {
            [delegate restClient:self copyPathFailedWithError:request.error];
        }
    } else {
        NSDictionary *params = (NSDictionary *)request.userInfo;
		
        if ([delegate respondsToSelector:@selector(restClient:copiedPath:toPath:)]) {
            [delegate restClient:self copiedPath:[params valueForKey:@"from_path"] toPath:[params valueForKey:@"to_path"]];
        }
    }
	
	@synchronized (requests) {
		[requests removeObject:request];
	}
}


- (void)createCopyRef:(NSString *)path {
    NSDictionary* userInfo = [NSDictionary dictionaryWithObject:path forKey:@"path"];
    NSString *fullPath = [NSString stringWithFormat:@"/copy_ref/%@%@", root, path];
    NSMutableURLRequest* urlRequest =
	[self requestWithHost:kDBDropboxAPIHost path:fullPath parameters:nil method:@"POST"];
	
    DBRequest* request = [[DBRequest alloc] initWithURLRequest:urlRequest andInformTarget:self selector:@selector(requestDidCreateCopyRef:)];
	
    request.userInfo = userInfo;
    [requests addObject:request];
}

- (void)requestDidCreateCopyRef:(DBRequest *)request {
    NSDictionary *result = [request parseResponseAsType:[NSDictionary class]];
    if (!result) {
        [self checkForAuthenticationFailure:request];
        if ([delegate respondsToSelector:@selector(restClient:createCopyRefFailedWithError:)]) {
            [delegate restClient:self createCopyRefFailedWithError:request.error];
        }
    } else {
        NSString *copyRef = [result objectForKey:@"copy_ref"];
        if ([delegate respondsToSelector:@selector(restClient:createdCopyRef:)]) {
            [delegate restClient:self createdCopyRef:copyRef];
        }
    }
	
    [requests removeObject:request];
}


- (void)copyFromRef:(NSString*)copyRef toPath:(NSString *)toPath {
    NSDictionary *params =
	[NSDictionary dictionaryWithObjectsAndKeys:
	 copyRef, @"from_copy_ref",
	 root, @"root",
	 toPath, @"to_path", nil];
	
    NSString *fullPath = [NSString stringWithFormat:@"/fileops/copy/"];
    NSMutableURLRequest* urlRequest =
	[self requestWithHost:kDBDropboxAPIHost path:fullPath parameters:params method:@"POST"];
	
    DBRequest* request = [[DBRequest alloc] initWithURLRequest:urlRequest andInformTarget:self selector:@selector(requestDidCopyFromRef:)];
	
    request.userInfo = params;
    [requests addObject:request];
}

- (void)requestDidCopyFromRef:(DBRequest *)request {
    NSDictionary *result = [request parseResponseAsType:[NSDictionary class]];
    if (!result) {
        [self checkForAuthenticationFailure:request];
        if ([delegate respondsToSelector:@selector(restClient:copyFromRefFailedWithError:)]) {
            [delegate restClient:self copyFromRefFailedWithError:request.error];
        }
    } else {
        NSString *copyRef = [request.userInfo objectForKey:@"from_copy_ref"];
        DBMetadata *metadata = [[DBMetadata alloc] initWithDictionary:result];
        if ([delegate respondsToSelector:@selector(restClient:copiedRef:to:)]) {
            [delegate restClient:self copiedRef:copyRef to:metadata];
        }
    }
	
    [requests removeObject:request];
}


- (void)deletePath:(NSString*)path {
    NSDictionary* params = [NSDictionary dictionaryWithObjectsAndKeys:
							root, @"root",
							path, @"path", nil];
	
    NSMutableURLRequest* urlRequest = 
	[self requestWithHost:kDBDropboxAPIHost path:@"/fileops/delete" 
			   parameters:params method:@"POST"];
	
    DBRequest* request = [self requestWithURLRequest:urlRequest selector:@selector(requestDidDeletePath:)];
    request.userInfo = params;
	@synchronized (requests) {
		[requests addObject:request];
	}
}



- (void)requestDidDeletePath:(DBRequest*)request {
    if (request.error) {
        [self checkForAuthenticationFailure:request];
        if ([delegate respondsToSelector:@selector(restClient:deletePathFailedWithError:)]) {
            [delegate restClient:self deletePathFailedWithError:request.error];
        }
    } else {
        if ([delegate respondsToSelector:@selector(restClient:deletedPath:)]) {
            NSString* path = [request.userInfo objectForKey:@"path"];
            [delegate restClient:self deletedPath:path];
        }
    }
	
	@synchronized (requests) {
		[requests removeObject:request];
	}
}




- (void)createFolder:(NSString*)path
{
    NSDictionary* params = [NSDictionary dictionaryWithObjectsAndKeys:
							root, @"root",
							path, @"path", nil];
	
    NSString* fullPath = @"/fileops/create_folder";
    NSMutableURLRequest* urlRequest = [self requestWithHost:kDBDropboxAPIHost path:fullPath parameters:params method:@"POST"];
    DBRequest* request = [self requestWithURLRequest:urlRequest selector:@selector(requestDidCreateDirectory:)];
    request.userInfo = params;

	@synchronized (requests) {
		[requests addObject:request];
	}
}



- (void)requestDidCreateDirectory:(DBRequest*)request {
    if (request.error) {
        [self checkForAuthenticationFailure:request];
        if ([delegate respondsToSelector:@selector(restClient:createFolderFailedWithError:)]) {
            [delegate restClient:self createFolderFailedWithError:request.error];
        }
    } else {
        NSDictionary* result = (NSDictionary*)[request resultJSON];
        DBMetadata* metadata = [[DBMetadata alloc] initWithDictionary:result];
        if ([delegate respondsToSelector:@selector(restClient:createdFolder:)]) {
            [delegate restClient:self createdFolder:metadata];
        }
    }
	
	@synchronized (requests) {
		[requests removeObject:request];
	}
}



- (void)loadAccountInfo
{
    NSURLRequest* urlRequest = [self requestWithHost:kDBDropboxAPIHost path:@"/account/info" parameters:nil];
    DBRequest* request = [self requestWithURLRequest:urlRequest selector:@selector(requestDidLoadAccountInfo:)];
    request.userInfo = [NSDictionary dictionaryWithObjectsAndKeys:root, @"root", nil];
	
	@synchronized (requests) {
		[requests addObject:request];
	}
}


- (void)requestDidLoadAccountInfo:(DBRequest*)request
{
    if (request.error) {
        [self checkForAuthenticationFailure:request];
        if ([delegate respondsToSelector:@selector(restClient:loadAccountInfoFailedWithError:)]) {
            [delegate restClient:self loadAccountInfoFailedWithError:request.error];
        }
    } else {
        NSDictionary* result = (NSDictionary*)[request resultJSON];
        DBAccountInfo* accountInfo = [[DBAccountInfo alloc] initWithDictionary:result];
        if ([delegate respondsToSelector:@selector(restClient:loadedAccountInfo:)]) {
            [delegate restClient:self loadedAccountInfo:accountInfo];
        }
    }
	
	@synchronized (requests) {
		[requests removeObject:request];
	}
}

- (void)searchPath:(NSString*)path forKeyword:(NSString*)keyword {
    NSDictionary* params = [NSDictionary dictionaryWithObject:keyword forKey:@"query"];
    NSString* fullPath = [NSString stringWithFormat:@"/search/%@%@", root, path];
    
    NSURLRequest* urlRequest = [self requestWithHost:kDBDropboxAPIHost path:fullPath parameters:params];
    DBRequest* request = [self requestWithURLRequest:urlRequest selector:@selector(requestDidSearchPath:)];
    request.userInfo = [NSDictionary dictionaryWithObjectsAndKeys:path, @"path", keyword, @"keyword", nil];

	@synchronized (requests) {
		[requests addObject:request];
	}
}


- (void)requestDidSearchPath:(DBRequest*)request {
    if (request.error) {
        [self checkForAuthenticationFailure:request];
        if ([delegate respondsToSelector:@selector(restClient:searchFailedWithError:)]) {
            [delegate restClient:self searchFailedWithError:request.error];
        }
    } else {
        NSMutableArray* results = nil;
        if ([[request resultJSON] isKindOfClass:[NSArray class]]) {
            NSArray* response = (NSArray*)[request resultJSON];
            results = [NSMutableArray arrayWithCapacity:[response count]];
            for (NSDictionary* dict in response) {
                DBMetadata* metadata = [[DBMetadata alloc] initWithDictionary:dict];
                [results addObject:metadata];
            }
        }
        NSString* path = [request.userInfo objectForKey:@"path"];
        NSString* keyword = [request.userInfo objectForKey:@"keyword"];
        
        if ([delegate respondsToSelector:@selector(restClient:loadedSearchResults:forPath:keyword:)]) {
            [delegate restClient:self loadedSearchResults:results forPath:path keyword:keyword];
        }
    }

	@synchronized (requests) {
		[requests removeObject:request];
	}
}


- (void)loadSharableLinkForFile:(NSString*)path {
    NSString* fullPath = [NSString stringWithFormat:@"/shares/%@%@", root, path];
	
    NSURLRequest* urlRequest = [self requestWithHost:kDBDropboxAPIHost path:fullPath parameters:nil];
	
    DBRequest* request = [self requestWithURLRequest:urlRequest selector:@selector(requestDidLoadSharableLink:)];
    request.userInfo =  [NSDictionary dictionaryWithObject:path forKey:@"path"];

	@synchronized (requests) {
		[requests addObject:request];
	}
}

- (void)requestDidLoadSharableLink:(DBRequest*)request {
    if (request.error) {
        [self checkForAuthenticationFailure:request];
        if ([delegate respondsToSelector:@selector(restClient:loadSharableLinkFailedWithError:)]) {
            [delegate restClient:self loadSharableLinkFailedWithError:request.error];
        }
    } else {
        NSString* sharableLink = [(NSDictionary*)request.resultJSON objectForKey:@"url"];
        NSString* path = [request.userInfo objectForKey:@"path"];
        if ([delegate respondsToSelector:@selector(restClient:loadedSharableLink:forFile:)]) {
            [delegate restClient:self loadedSharableLink:sharableLink forFile:path];
        }
    }

	@synchronized (requests) {
		[requests removeObject:request];
	}
}


- (void)loadStreamableURLForFile:(NSString *)path {
    NSString* fullPath = [NSString stringWithFormat:@"/media/%@%@", root, path];
    NSURLRequest* urlRequest =
	[self requestWithHost:kDBDropboxAPIHost path:fullPath parameters:nil];
	
    DBRequest *request = [self requestWithURLRequest:urlRequest selector:@selector(requestDidLoadStreamableURL:)];
    request.userInfo = [NSDictionary dictionaryWithObject:path forKey:@"path"];

	@synchronized (requests) {
		[requests addObject:request];
	}
}

- (void)requestDidLoadStreamableURL:(DBRequest *)request {
    if (request.error) {
        [self checkForAuthenticationFailure:request];
        if ([delegate respondsToSelector:@selector(restClient:loadStreamableURLFailedWithError:)]) {
            [delegate restClient:self loadStreamableURLFailedWithError:request.error];
        }
    } else {
        NSDictionary *response = [request parseResponseAsType:[NSDictionary class]];
        NSURL *url = [NSURL URLWithString:[response objectForKey:@"url"]];
        NSString *path = [request.userInfo objectForKey:@"path"];
        if ([delegate respondsToSelector:@selector(restClient:loadedStreamableURL:forFile:)]) {
            [delegate restClient:self loadedStreamableURL:url forFile:path];
        }
    }

	@synchronized (requests) {
		[requests removeObject:request];
	}
}


- (NSUInteger)requestCount {
	return [requests count] + [loadRequests count] + [imageLoadRequests count] + [uploadRequests count];
}


#pragma mark private methods

+ (NSString*)escapePath:(NSString*)path {
    CFStringEncoding encoding = CFStringConvertNSStringEncodingToEncoding(NSUTF8StringEncoding);
    NSString *escapedPath = 
	(__bridge_transfer NSString *)CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault,
														(__bridge CFStringRef)path,
														NULL,
														(CFStringRef)@":?=,!$&'()*+;[]@#~",
														encoding);
    
    return escapedPath;
}

+ (NSString *)bestLanguage {
    static NSString *preferredLang = nil;
    if (!preferredLang) {
        NSString *lang = [[NSLocale preferredLanguages] objectAtIndex:0];
        if ([[[NSBundle mainBundle] localizations] containsObject:lang])
            preferredLang = [lang copy];
        else
            preferredLang =  @"en";
    }
    return preferredLang;
}

+ (NSString *)userAgent {
    static NSString *userAgent;
    if (!userAgent) {
        NSBundle *bundle = [NSBundle mainBundle];
        NSString *appName = [[bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"]
							 stringByReplacingOccurrencesOfString:@" " withString:@""];
        NSString *appVersion = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        userAgent =
		[[NSString alloc] initWithFormat:@"%@/%@ OfficialDropboxIosSdk/%@", appName, appVersion, kDBSDKVersion];
    }
    return userAgent;
}

- (NSMutableURLRequest*)requestWithHost:(NSString*)host path:(NSString*)path 
							 parameters:(NSDictionary*)params {
    
    return [self requestWithHost:host path:path parameters:params method:nil];
}


- (NSMutableURLRequest*)requestWithHost:(NSString*)host path:(NSString*)path 
							 parameters:(NSDictionary*)params method:(NSString*)method {
    
    NSString* escapedPath = [DBRestClient escapePath:path];
    NSString* urlString = [NSString stringWithFormat:@"%@://%@/%@%@", 
						   kDBProtocolHTTPS, host, kDBDropboxAPIVersion, escapedPath];
    NSURL* url = [NSURL URLWithString:urlString];
	
    NSMutableDictionary *allParams = 
	[NSMutableDictionary dictionaryWithObject:[DBRestClient bestLanguage] forKey:@"locale"];
    if (params) {
        [allParams addEntriesFromDictionary:params];
    }
	
    NSArray *extraParams = [MPURLRequestParameter parametersFromDictionary:allParams];
    NSArray *paramList = 
    [[self.credentialStore oauthParameters] arrayByAddingObjectsFromArray:extraParams];
	
    MPOAuthURLRequest* oauthRequest = [[MPOAuthURLRequest alloc] initWithURL:url andParameters:paramList];
    if (method) {
        oauthRequest.HTTPMethod = method;
    }
	
    NSMutableURLRequest* urlRequest = [oauthRequest 
									   urlRequestSignedWithSecret:self.credentialStore.signingKey 
									   usingMethod:self.credentialStore.signatureMethod];
    [urlRequest setTimeoutInterval:20];
    [urlRequest setValue:[DBRestClient userAgent] forHTTPHeaderField:@"User-Agent"];
    return urlRequest;
}


- (void)checkForAuthenticationFailure:(DBRequest*)request {
    if (request.error && request.error.code == 401 && [request.error.domain isEqual:DBErrorDomain]) {
        [session.delegate sessionDidReceiveAuthorizationFailure:session userId:userId];
    }
}

- (MPOAuthCredentialConcreteStore *)credentialStore {
    return [session credentialStoreForUserId:userId];
}

@end