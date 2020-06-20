//
//  KKJSBridgeAjaxURLProtocol.m
//  KKJSBridge
//
//  Created by karos li on 2020/6/20.
//

#import "KKJSBridgeAjaxURLProtocol.h"
#import "KKJSBridgeXMLBodyCacheRequest.h"
#import "KKJSBridgeURLRequestSerialization.h"
#import "KKJSBridgeFormDataFile.h"

static NSString * const kKKJSBridgeNSURLProtocolKey = @"kKKJSBridgeNSURLProtocolKey";
static NSString * const kKKJSBridgeRequestId = @"KKJSBridge-RequestId";

@interface KKJSBridgeAjaxURLProtocol () <NSURLSessionDelegate>

@property (nonatomic, strong) NSURLSessionDataTask *customTask;
@property (nonatomic, copy) NSString *requestId;

@end

@implementation KKJSBridgeAjaxURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSDictionary *headers = request.allHTTPHeaderFields;
    if ([headers.allKeys containsObject:kKKJSBridgeRequestId]) {
        // 看看是否已经处理过了，防止无限循环
        if ([NSURLProtocol propertyForKey:kKKJSBridgeNSURLProtocolKey inRequest:request]) {
            return NO;
        }
        
        return YES;
    }

    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

+ (BOOL)requestIsCacheEquivalent:(NSURLRequest *)a toRequest:(NSURLRequest *)b {
    return [super requestIsCacheEquivalent:a toRequest:b];
}

- (instancetype)initWithRequest:(NSURLRequest *)request cachedResponse:(NSCachedURLResponse *)cachedResponse client:(id<NSURLProtocolClient>)client {
    self = [super initWithRequest:request cachedResponse:cachedResponse client:client];
    if (self) {
        
    }
    return self;
}

- (void)startLoading {
    NSMutableURLRequest *mutableReqeust = [[self request] mutableCopy];
    //给我们处理过的请求设置一个标识符, 防止无限循环,
    [NSURLProtocol setProperty:@YES forKey:kKKJSBridgeNSURLProtocolKey inRequest:mutableReqeust];
    
    NSDictionary *headers = mutableReqeust.allHTTPHeaderFields;
    NSString *requestId = headers[kKKJSBridgeRequestId];
    
    NSDictionary *bodyReqeust = [KKJSBridgeXMLBodyCacheRequest getRequestBody:requestId];
    if (bodyReqeust) {
        // 移除临时的请求头
        NSMutableDictionary *mutableHeaders = [headers mutableCopy];
        [mutableHeaders removeObjectForKey:kKKJSBridgeRequestId];
        mutableReqeust.allHTTPHeaderFields = mutableHeaders;
        
        // 从把缓存的 body 设置给 request
        [self setBodyRequest:bodyReqeust toRequest:mutableReqeust];
        
        // 发送请求
        self.requestId = requestId;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration] delegate:self delegateQueue:nil];
        self.customTask = [session dataTaskWithRequest:mutableReqeust];
        [self.customTask resume];
    } else {
        [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:@"KKJSBridge" code:-999 userInfo:@{@"error": @"can not find cached body request"}]];
    }
}

- (void)stopLoading {
    if (self.customTask != nil) {
        [self.customTask  cancel];
    }
    
    // 清除缓存
    [KKJSBridgeXMLBodyCacheRequest deleteRequestBody:self.requestId];
}

#pragma mark - NSURLSessionDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    // 清除缓存
    [KKJSBridgeXMLBodyCacheRequest deleteRequestBody:self.requestId];
    
    if (error) {
        [self.client URLProtocol:self didFailWithError:error];
    } else {
        [self.client URLProtocolDidFinishLoading:self];
    }
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageAllowed];
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    [self.client URLProtocol:self didLoadData:data];
}

#pragma mark - util
/**
 
 type BodyType = "String" | "Blob" | "FormData" | "ArrayBuffer";
 
 {
    //请求唯一id
    requestId,
    //当前 href url
    requestHref,
    //请求 Url
    requestUrl,
    //body 类型
    bodyType
    //body 具体值
    value
}
*/
- (void)setBodyRequest:(NSDictionary *)bodyRequest toRequest:(NSMutableURLRequest *)request {
    NSData *data = nil;
    NSString *bodyType = bodyRequest[@"bodyType"];
    id value = bodyRequest[@"value"];
    if ([bodyType isEqualToString:@"Blob"]) {
        data = [self dataFromBase64:value];
    } else if ([bodyType isEqualToString:@"ArrayBuffer"]) {
        data = [self dataFromBase64:value];
    } else if ([bodyType isEqualToString:@"FormData"]) {
        [self setFormData:value toRequest:request];
        return;
    } else {//String
        if ([value isKindOfClass:NSDictionary.class]) {
            // application/json
            data = [NSJSONSerialization dataWithJSONObject:data options:0 error:nil];
        } else if ([value isKindOfClass:NSString.class]) {
            // application/x-www-form-urlencoded
            // name1=value1&name2=value2
            data = [value dataUsingEncoding:NSUTF8StringEncoding];
        } else {
            data = value;
        }
    }
    
    request.HTTPBody = data;
}

- (NSData *)dataFromBase64:(NSString *)base64 {
    // data:image/png;base64,iVBORw0...
    NSArray<NSString *> *components = [base64 componentsSeparatedByString:@","];
    if (components.count != 2) {
        return nil;
    }
    
    NSString *splitBase64 = components.lastObject;
    NSUInteger paddedLength = splitBase64.length + (splitBase64.length % 4);
    NSString *fixBase64 = [splitBase64 stringByPaddingToLength:paddedLength withString:@"=" startingAtIndex:0];
    NSData *data = [[NSData alloc] initWithBase64EncodedString:fixBase64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
    
    return data;
}

- (void)setFormData:(NSDictionary *)formDataJson toRequest:(NSMutableURLRequest *)request {
    NSArray<NSString *> *fileKeys = formDataJson[@"fileKeys"];
    NSArray<NSArray *> *formData = formDataJson[@"formData"];
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    NSMutableArray<KKJSBridgeFormDataFile *> *fileDatas = [NSMutableArray array];
    
    for (NSArray *pair in formData) {
        if (pair.count < 2) {
            continue;
        }
        
        NSString *key = pair[0];
        if ([fileKeys containsObject:key]) {// 说明存储的是个文件数据
            NSDictionary *fileJson = pair[1];
            KKJSBridgeFormDataFile *fileData = [KKJSBridgeFormDataFile new];
            fileData.key = key;
            fileData.size = [fileJson[@"size"] unsignedIntegerValue];
            fileData.type = fileJson[@"type"];
            
            if (fileJson[@"name"] && [fileJson[@"name"] length] > 0) {
                fileData.fileName = fileJson[@"name"];
            } else {
                fileData.fileName = fileData.key;
            }
            if (fileJson[@"lastModified"] && [fileJson[@"lastModified"] unsignedIntegerValue] > 0) {
                fileData.lastModified = [fileJson[@"lastModified"] unsignedIntegerValue];
            }
            if ([fileJson[@"data"] isKindOfClass:NSString.class]) {
                NSString *base64 = (NSString *)fileJson[@"data"];
                NSData *byteData = [self dataFromBase64:base64];
                fileData.data = byteData;
            }
            
            [fileDatas addObject:fileData];
        } else {
            params[key] = pair[1];
        }
    }
    
    KKJSBridgeURLRequestSerialization *serializer = [KKJSBridgeAjaxURLProtocol urlRequestSerialization];
    [serializer multipartFormRequestWithRequest:request parameters:params constructingBodyWithBlock:^(id<KKJSBridgeMultipartFormData>  _Nonnull formData) {
        for (KKJSBridgeFormDataFile *fileData in fileDatas) {
            [formData appendPartWithFileData:fileData.data name:fileData.key fileName:fileData.fileName mimeType:fileData.type];
        }
    } error:nil];
}

#pragma mark - KKJSBridgeURLRequestSerialization

+ (KKJSBridgeURLRequestSerialization *)urlRequestSerialization {
    static KKJSBridgeURLRequestSerialization *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [KKJSBridgeURLRequestSerialization new];
    });
    
    return instance;
}

@end