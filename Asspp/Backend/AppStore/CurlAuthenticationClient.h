#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface CurlAuthenticationResponse : NSObject
@property(nonatomic, readonly, copy) NSData *data;
@property(nonatomic, readonly, copy) NSArray<NSArray<NSString *> *> *headers;
@property(nonatomic, readonly) NSInteger statusCode;
@property(nonatomic, readonly) NSInteger httpVersion;
@end

/// One transfer, with local TLS verification and no automatic redirects.
@interface CurlAuthenticationClient : NSObject
- (nullable CurlAuthenticationResponse *)performRequest:(NSURLRequest *)request
                                          caBundlePath:(NSString *)caBundlePath error:(NSError **)error;
- (void)cancel;
+ (NSString *)runtimeDescription;
@end
NS_ASSUME_NONNULL_END
