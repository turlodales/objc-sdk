//
//  QNUploader.h
//  QiniuSDK
//
//  Created by bailong on 14-9-28.
//  Copyright (c) 2014年 Qiniu. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "../Common/QNConfig.h"
#import "../Http/QNHttpManager.h"

#import "QNUploadManager.h"
#import "QNResumeUpload.h"

@interface QNUploadOption ()
@property (nonatomic, readonly, copy) NSDictionary *convertToPostParams;
@end

@implementation QNUploadOption

- (NSMutableDictionary *)convertToPostParams {
	NSMutableDictionary *params = [NSMutableDictionary dictionaryWithDictionary:self.params];

	return params;
}

@end

@interface QNUploadManager ()
@property QNHttpManager *httpManager;
@end

@implementation QNUploadManager

+ (instancetype)create  /*(persistent)*/
{
	return [[QNUploadManager alloc] init];
}

- (instancetype)init {
	if (self = [super init]) {
		self.httpManager = [[QNHttpManager alloc] init];
	}

	return self;
}

- (NSError *) putData:(NSData *)data
              withKey:(NSString *)key
            withToken:(NSString *)token
    withCompleteBlock:(QNUpCompleteBlock)block
           withOption:(QNUploadOption *)option {
	NSMutableDictionary *parameters = [NSMutableDictionary dictionary];

	if (key && ![key isEqualToString:kQiniuUndefinedKey]) {
		parameters[@"key"] = key;
	}

	if (!key) {
		key = kQiniuUndefinedKey;
	}

	parameters[@"token"] = token;

	if (option.params) {
		[parameters addEntriesFromDictionary:option.convertToPostParams];
	}

	NSString *mimeType = option.mimeType;

	if (!mimeType) {
		mimeType = @"application/octet-stream";
	}

	QNProgressBlock p = nil;

	if (option && option.progress) {
		p = ^(float percent) {
			option.progress(key, percent);
		};
	}

	QNCompleteBlock _block = ^(QNResponseInfo *info, NSDictionary *resp)
	{
		block(info, key, resp);
	};

	return [self.httpManager multipartPost:[NSString stringWithFormat:@"http://%@", kUpHost]
	                              withData:data
	                            withParams:parameters
	                          withFileName:key
	                          withMimeType:mimeType
	                     withCompleteBlock:_block
	                     withProgressBlock:p];
}

- (NSError *) putFile:(NSString *)filePath
              withKey:(NSString *)key
            withToken:(NSString *)token
    withCompleteBlock:(QNUpCompleteBlock)block
           withOption:(QNUploadOption *)option {
	NSError *error = nil;

	@autoreleasepool {
		NSDictionary *fileAttr = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:&error];

		if (error) {
			return error;
		}

		NSNumber *fileSizeNumber = fileAttr[NSFileSize];
		UInt32 fileSize = [fileSizeNumber intValue];
		NSData *data = [NSData dataWithContentsOfFile:filePath options:NSDataReadingMappedIfSafe error:&error];
		if (error) {
			return error;
		}
		if (fileSize <= kPutThreshHold) {
			return [self putData:data withKey:key withToken:token withCompleteBlock:block withOption:option];
		}

		QNCompleteBlock _block = ^(QNResponseInfo *info, NSDictionary *resp)
		{
			block(info, key, resp);
		};

		QNResumeUpload *up = [[QNResumeUpload alloc]
		                      initWithData:data
		                                  withSize:fileSize
		                                   withKey:key
		                                 withToken:token
		                         withCompleteBlock:_block
		                                withOption:option];

		error = [up run];
	}
	return error;
}

@end
