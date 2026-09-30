#import "CurlAuthenticationClient.h"
#include <curl/curl.h>

@interface CurlAuthenticationResponse ()
@property(nonatomic, readwrite, copy) NSData *data;
@property(nonatomic, readwrite, copy) NSArray<NSArray<NSString *> *> *headers;
@property(nonatomic, readwrite) NSInteger statusCode;
@property(nonatomic, readwrite) NSInteger httpVersion;
@end
@implementation CurlAuthenticationResponse
@end

@interface CurlAuthenticationClient ()
@property(nonatomic, strong) NSMutableData *body;
@property(nonatomic, strong) NSMutableArray<NSArray<NSString *> *> *responseHeaders;
@property(nonatomic, strong) NSLock *lock;
@property(nonatomic) BOOL cancelled;
@property(nonatomic) NSUInteger headerBytes;
@end

static size_t ReceiveBody(char *bytes, size_t size, size_t count, void *context) {
    CurlAuthenticationClient *client = (__bridge CurlAuthenticationClient *)context;
    if (size && count > SIZE_MAX / size) return 0;
    size_t length = size * count;
    if (length > (4 << 20) || client.body.length > (4 << 20) - length) return 0;
    [client.body appendBytes:bytes length:length];
    return length;
}

static size_t ReceiveHeader(char *bytes, size_t size, size_t count, void *context) {
    CurlAuthenticationClient *client = (__bridge CurlAuthenticationClient *)context;
    if (size && count > SIZE_MAX / size) return 0;
    size_t length = size * count;
    if (length > (1 << 20) || client.headerBytes > (1 << 20) - length) return 0;
    client.headerBytes += length;
    NSString *line = [[NSString alloc] initWithBytes:bytes length:length encoding:NSISOLatin1StringEncoding];
    if ([line hasPrefix:@"HTTP/"]) {
        [client.responseHeaders removeAllObjects];
        [client.body setLength:0];
    } else {
        NSRange separator = [line rangeOfString:@":"];
        if (separator.location != NSNotFound) {
            NSString *name = [[line substringToIndex:separator.location] lowercaseString];
            NSString *value = [[line substringFromIndex:separator.location + 1]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            [client.responseHeaders addObject:@[name, value]];
        }
    }
    return length;
}

static int TransferProgress(void *context, curl_off_t a, curl_off_t b, curl_off_t c, curl_off_t d) {
    CurlAuthenticationClient *client = (__bridge CurlAuthenticationClient *)context;
    [client.lock lock];
    BOOL cancelled = client.cancelled;
    [client.lock unlock];
    return cancelled ? 1 : 0;
}

@implementation CurlAuthenticationClient
- (instancetype)init {
    if ((self = [super init])) {
        _body = [NSMutableData data];
        _responseHeaders = [NSMutableArray array];
        _lock = [NSLock new];
    }
    return self;
}
- (void)cancel {
    [self.lock lock];
    self.cancelled = YES;
    [self.lock unlock];
}
+ (NSString *)runtimeDescription {
    const curl_version_info_data *info = curl_version_info(CURLVERSION_NOW);
    return [NSString stringWithFormat:@"libcurl/%s %s HTTP/1.1 direct", info->version, info->ssl_version ?: "unknown-TLS"];
}
- (CurlAuthenticationResponse *)performRequest:(NSURLRequest *)request
                                  caBundlePath:(NSString *)caBundlePath error:(NSError **)error {
    static dispatch_once_t once;
    static CURLcode initialized;
    dispatch_once(&once, ^{ initialized = curl_global_init(CURL_GLOBAL_DEFAULT); });
    CURL *handle = initialized == CURLE_OK ? curl_easy_init() : NULL;
    if (!handle) {
        if (error) *error = [NSError errorWithDomain:@"Asspp.CurlTransport" code:CURLE_FAILED_INIT userInfo:nil];
        return nil;
    }
    struct curl_slist *headers = NULL;
    for (NSString *name in request.allHTTPHeaderFields) {
        NSString *line = [NSString stringWithFormat:@"%@: %@", name, request.allHTTPHeaderFields[name]];
        headers = curl_slist_append(headers, line.UTF8String);
    }
    headers = curl_slist_append(headers, "Expect:");
    NSData *payload = request.HTTPBody;
    CURLcode result = CURLE_OK;
#define SET_OPTION(option, value) do { if (result == CURLE_OK) result = curl_easy_setopt(handle, option, value); } while (0)
    SET_OPTION(CURLOPT_URL, request.URL.absoluteString.UTF8String);
    SET_OPTION(CURLOPT_PROTOCOLS_STR, "http,https");
    SET_OPTION(CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_1);
    SET_OPTION(CURLOPT_SSLVERSION, CURL_SSLVERSION_TLSv1_2);
    SET_OPTION(CURLOPT_SSL_VERIFYPEER, 1L);
    SET_OPTION(CURLOPT_SSL_VERIFYHOST, 2L);
    SET_OPTION(CURLOPT_CAINFO, caBundlePath.UTF8String);
    SET_OPTION(CURLOPT_FOLLOWLOCATION, 0L);
    SET_OPTION(CURLOPT_NOSIGNAL, 1L);
    SET_OPTION(CURLOPT_CONNECTTIMEOUT, 30L);
    SET_OPTION(CURLOPT_TIMEOUT, 60L);
    SET_OPTION(CURLOPT_PROXY, "");
    SET_OPTION(CURLOPT_HTTPHEADER, headers);
    SET_OPTION(CURLOPT_WRITEFUNCTION, ReceiveBody);
    SET_OPTION(CURLOPT_WRITEDATA, (__bridge void *)self);
    SET_OPTION(CURLOPT_HEADERFUNCTION, ReceiveHeader);
    SET_OPTION(CURLOPT_HEADERDATA, (__bridge void *)self);
    SET_OPTION(CURLOPT_NOPROGRESS, 0L);
    SET_OPTION(CURLOPT_XFERINFOFUNCTION, TransferProgress);
    SET_OPTION(CURLOPT_XFERINFODATA, (__bridge void *)self);
    if (payload) {
        SET_OPTION(CURLOPT_POSTFIELDS, payload.bytes ?: "");
        SET_OPTION(CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)payload.length);
    }
    SET_OPTION(CURLOPT_CUSTOMREQUEST, (request.HTTPMethod ?: @"GET").UTF8String);
#undef SET_OPTION
    if (result == CURLE_OK) result = curl_easy_perform(handle);
    long status = 0, version = 0;
    curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, &status);
    curl_easy_getinfo(handle, CURLINFO_HTTP_VERSION, &version);
    curl_easy_cleanup(handle);
    curl_slist_free_all(headers);
    if (result != CURLE_OK) {
        // Do not expose libcurl's URL-bearing error buffer.
        if (error) *error = [NSError errorWithDomain:@"Asspp.CurlTransport" code:result userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Authentication connection failed (curl %d).", result]
        }];
        return nil;
    }
    CurlAuthenticationResponse *response = [CurlAuthenticationResponse new];
    response.data = [self.body copy];
    response.headers = [self.responseHeaders copy];
    response.statusCode = status;
    response.httpVersion = version;
    return response;
}
@end
