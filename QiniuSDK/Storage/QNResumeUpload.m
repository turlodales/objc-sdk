//
//  QNResumeUpload.m
//  QiniuSDK
//
//  Created by bailong on 14/10/1.
//  Copyright (c) 2014年 Qiniu. All rights reserved.
//

#import "QNResumeUpload.h"
#import "QNUploadManager.h"
#import "QNBase64.h"
#import "QNConfig.h"
#import "QNResponseInfo.h"
#import "QNHttpManager.h"
#import "QNUploadOption+Private.h"

@interface QNResumeUpload ()

@property (nonatomic, strong) NSData *data;
@property (nonatomic, weak) QNHttpManager *httpManager;
@property UInt32 size;
@property (nonatomic) int uploadedCount;
@property (nonatomic, strong) NSString *key;
@property (nonatomic, strong) NSString *token;
@property (nonatomic, strong) QNUploadOption *option;
@property (nonatomic, strong) QNUpCompleteBlock complete;
@property (nonatomic, strong) NSMutableArray *contexts;
@property (nonatomic, readonly) UInt32 count;
@property (nonatomic, readonly) BOOL reachEnd;
@property (nonatomic, readonly, getter = isCancelled) BOOL cancelled;
@property (nonatomic, weak) id <QNRecorderDelegate> recorder;

- (void)makeBlock:(NSString *)uphost
           offset:(UInt32)offset
             size:(UInt32)size
         progress:(QNInternalProgressBlock)progressBlock
         complete:(QNCompleteBlock)complete;

- (void)putChunk:(NSString *)uphost
          offset:(UInt32)offset
            size:(UInt32)size
         context:(NSString *)context
        progress:(QNInternalProgressBlock)progressBlock
        complete:(QNCompleteBlock)complete;

- (void)putBlock:(NSString *)uphost
          offset:(UInt32)offset
            size:(UInt32)size
        progress:(QNInternalProgressBlock)progressBlock
        complete:(QNCompleteBlock)complete;

- (void)makeFile:(NSString *)uphost
        complete:(QNCompleteBlock)complete;

@end

@implementation QNResumeUpload

- (instancetype)initWithData:(NSData *)data
                    withSize:(UInt32)size
                     withKey:(NSString *)key
                   withToken:(NSString *)token
           withCompleteBlock:(QNUpCompleteBlock)block
                  withOption:(QNUploadOption *)option
                withRecorder:(id <QNRecorderDelegate> )recorder
             withHttpManager:(QNHttpManager *)http {
	if (self = [super init]) {
		_data = data;
		_size = size;
		_key = key;
        _token = [NSString stringWithFormat:@"UpToken %@", token];
		_option = option;
		_complete = block;
		_uploadedCount = 0;
		_recorder = recorder;
        _httpManager = http;
        _contexts = [[NSMutableArray alloc] initWithCapacity:(size + kQNBlockSize - 1) / kQNBlockSize];
	}

	return self;
}

- (void)increaseCount {
	//single thread, no sync
	self->_uploadedCount++;
}

- (BOOL)reachEnd {
	return self.uploadedCount == (int)self.count;
}

- (UInt32)count {
	return (self.size + kQNBlockSize - 1) / kQNBlockSize;
}

- (void)makeBlock:(NSString *)uphost
           offset:(UInt32)offset
             size:(UInt32)size
         progress:(QNInternalProgressBlock)progressBlock
         complete:(QNCompleteBlock)complete {
    UInt32 chunkSize = [QNResumeUpload calcChunkSize:size offset:0];
	NSData *data = [self.data subdataWithRange:NSMakeRange(offset, (unsigned int)chunkSize)];
	NSString *url = [[NSString alloc] initWithFormat:@"http://%@/mkblk/%u", uphost, size];
	[self post:url withData:data withCompleteBlock:complete withProgressBlock:progressBlock];
}

- (void)putChunk:(NSString *)uphost
          offset:(UInt32)offset
            size:(UInt32)size
         context:(NSString *)context
        progress:(QNInternalProgressBlock)progressBlock
        complete:(QNCompleteBlock)complete {
	NSData *data = [self.data subdataWithRange:NSMakeRange(offset, (unsigned int)size)];
	UInt32 chunkOffset = offset % kQNBlockSize;
	NSString *url = [[NSString alloc] initWithFormat:@"http://%@/bput/%@/%u", uphost, context, (unsigned int)chunkOffset];

	// Todo: check crc
	[self post:url withData:data withCompleteBlock:complete withProgressBlock:progressBlock];
}

+ (UInt32)calcChunkSize:(UInt32)blockSize
                 offset:(UInt32)offset {
	UInt32 remainLength = blockSize - offset;
	return (UInt32)(kQNChunkSize < remainLength ? kQNChunkSize : remainLength);
}

+ (UInt32)calcBlockSize:(UInt32)fileSize
                 offset:(UInt32)offset {
	UInt32 remainLength = fileSize - offset;
	return (UInt32)(kQNBlockSize < remainLength ? kQNBlockSize : remainLength);
}

- (BOOL)isCancelled {
	return self.option && [self.option isCancelled];
}

- (void)putBlock:(NSString *)uphost
          offset:(UInt32)offset
            size:(UInt32)size
        progress:(QNInternalProgressBlock)progressBlock
        complete:(QNCompleteBlock)complete {
	QNCompleteBlock __block __weak weakChunkComplete;
	QNCompleteBlock chunkComplete;
	__block BOOL isMakeBlock = YES;
    __block UInt32 chunkOffset = 0;
    QNInternalProgressBlock _progressBlock;
    QNInternalProgressBlock weakChunkProgress = _progressBlock =  ^(long long totalBytesWritten, long long totalBytesExpectedToWrite) {
        if (progressBlock) {
            progressBlock(chunkOffset + totalBytesWritten, size);
        }
	};
	//todo record
	weakChunkComplete = chunkComplete =  ^(QNResponseInfo *info, NSDictionary *resp) {
		if (self.isCancelled) {
			complete([QNResponseInfo cancel], nil);
			return;
		}
		if (info.error) {
//            if (isMakeBlock || info.stausCode == 701) {
			complete(info, nil);
			return;
//            }
		}
        NSString *context = [resp valueForKey:@"ctx"];
        _contexts[offset/kQNBlockSize] = context;

        isMakeBlock = NO;

		chunkOffset = [[resp valueForKey:@"offset"] intValue];
		if (chunkOffset == size) {
			complete(info, nil);
			return;
		}
		UInt32 chunkSize = [QNResumeUpload calcChunkSize:size offset:chunkOffset];
		[self putChunk:uphost offset:offset + chunkOffset size:chunkSize context:context progress:weakChunkProgress complete:weakChunkComplete];
	};

	[self makeBlock:kQNUpHost offset:offset size:size progress:_progressBlock complete:chunkComplete];
}

- (void)makeFile:(NSString *)uphost
        complete:(QNCompleteBlock)complete {
	NSString *mime;

	if (!self.option || !self.option.mimeType) {
		mime = @"";
	}
	else {
		mime = [[NSString alloc] initWithFormat:@"/mimetype/%@", [QNBase64 encodeString:self.option.mimeType]];
	}

	NSString *url = [[NSString alloc] initWithFormat:@"http://%@/mkfile/%u%@", uphost, (unsigned int)self.size, mime];

	if (self.key != nil) {
		NSString *keyStr = [[NSString alloc] initWithFormat:@"/key/%@", [QNBase64 encodeString:self.key]];
		url = [NSString stringWithFormat:@"%@%@", url, keyStr];
	}

	if (self.option && self.option.params) {
		NSEnumerator *e = [self.option.params keyEnumerator];

		for (id key = [e nextObject]; key != nil; key = [e nextObject]) {
			url = [NSString stringWithFormat:@"%@/%@/%@", url, key, [QNBase64 encodeString:(self.option.params)[key]]];
		}
	}

	NSMutableData *postData = [NSMutableData data];
	NSString *bodyStr = [self.contexts componentsJoinedByString:@","];
	[postData appendData:[bodyStr dataUsingEncoding:NSUTF8StringEncoding]];
	[self post:url withData:postData withCompleteBlock:complete withProgressBlock:nil];
}

- (void)         post:(NSString *)url
             withData:(NSData *)data
    withCompleteBlock:(QNCompleteBlock)completeBlock
    withProgressBlock:(QNInternalProgressBlock)progressBlock {
	NSDictionary *headers = @{ @"Authorization":self.token, @"Content-Type":@"application/octet-stream" };
	[_httpManager post:url withData:data withParams:nil withHeaders:headers withCompleteBlock:completeBlock withProgressBlock:progressBlock withCancelBlock:nil];
}

- (void)run {
	@autoreleasepool {
		//todo read from recorder
		QNInternalProgressBlock __block progressBlock;
		UInt32 __block blockOffset = 0;
		UInt32 __block blockSize = [QNResumeUpload calcBlockSize:self.size offset:blockOffset];
		QNInternalProgressBlock __block __weak weakProgressBlock = progressBlock = ^(long long totalBytesWritten, long long totalBytesExpectedToWrite) {
			if (self.option && self.option.progress) {
				float percent = (float)(blockOffset + totalBytesWritten) / (float)self.size;
				if (percent > 0.95) {
					percent = 0.95;
				}
				self.option.progress(self.key, percent);
			}
		};
		QNCompleteBlock __block __weak weakBlockComplete;
		QNCompleteBlock blockComplete;
		weakBlockComplete = blockComplete = ^(QNResponseInfo *info, NSDictionary *resp)
		{
			if (info.isCancelled) {
				self.complete(info, self.key, nil);
				return;
			}
			if (info.error != nil) {
				//todo retry
				self.complete(info, self.key, nil);
				return;
			}

			[self increaseCount];
			if (self.reachEnd) {
				QNCompleteBlock __block endBlock;
				__block BOOL retried = NO;
				QNCompleteBlock __block __weak weakEndBlock = endBlock = ^(QNResponseInfo *info, NSDictionary *resp) {
					if (info.stausCode != 614 && info.stausCode != 200 && info.stausCode >= 500) {
						if (retried) {
							self.complete(info, _key, nil);
							return;
						}
						retried = YES;
						[self makeFile:kQNUpHostBackup complete:weakEndBlock];
						return;
					}
					if (info.stausCode == 200 && self.option && self.option.progress) {
						self.option.progress(_key, 1.0);
					}
					self.complete(info, _key, resp);
				};

				[self makeFile:kQNUpHost complete:endBlock];
				return;
			}
			blockOffset += blockSize;
			blockSize = [QNResumeUpload calcBlockSize:self.size offset:blockOffset];
			[self putBlock:kQNUpHost offset:blockOffset size:blockSize progress:weakProgressBlock complete:weakBlockComplete];
		};

		[self putBlock:kQNUpHost offset:blockOffset size:blockSize progress:weakProgressBlock complete:weakBlockComplete];
	}
}

@end