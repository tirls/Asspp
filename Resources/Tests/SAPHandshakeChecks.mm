#import <Foundation/Foundation.h>
#import "SAPContext.h"
#include <iostream>
#include <stdexcept>

// Only public setup requests and a synthetic body. Never authenticate an account.
static NSDictionary *FetchPlist(NSURLSession *session, NSURL *url, NSDictionary *body = nil) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6" forHTTPHeaderField:@"User-Agent"];
    // Mirror production: setup endpoints choose their own plist response type.
    if ([url.host isEqualToString:@"init.itunes.apple.com"])
        [request setValue:@"application/xml" forHTTPHeaderField:@"Accept"];
    if (body) {
        request.HTTPMethod = @"POST";
        [request setValue:@"application/x-apple-plist" forHTTPHeaderField:@"Content-Type"];
        request.HTTPBody = [NSPropertyListSerialization dataWithPropertyList:body format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
    }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSData *result = nil;
    __block NSError *failure = nil;
    __block NSInteger status = 0;
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        result = data;
        failure = error;
        status = [(NSHTTPURLResponse *)response statusCode];
        dispatch_semaphore_signal(done);
    }];
    [task resume];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 65 * NSEC_PER_SEC))) {
        [task cancel];
        throw std::runtime_error("Public SAP setup request timed out");
    }
    if (failure || status != 200 || result.length > 1024 * 1024) {
        std::cerr << "Public setup HTTP " << status << ", network error " << failure.code << std::endl;
        throw std::runtime_error("Public SAP setup request failed");
    }
    id plist = [NSPropertyListSerialization propertyListWithData:result options:0 format:NULL error:NULL];
    if (!plist) {
        NSString *text = [[NSString alloc] initWithData:result encoding:NSUTF8StringEncoding];
        NSRange begin = [text rangeOfString:@"<plist"];
        NSRange end = [text rangeOfString:@"</plist>"];
        if (text && begin.location != NSNotFound && end.location != NSNotFound && end.location > begin.location) {
            NSData *inner = [[text substringWithRange:NSMakeRange(begin.location, NSMaxRange(end) - begin.location)] dataUsingEncoding:NSUTF8StringEncoding];
            plist = [NSPropertyListSerialization propertyListWithData:inner options:0 format:NULL error:NULL];
        }
    }
    if (![plist isKindOfClass:[NSDictionary class]]) throw std::runtime_error("Invalid public SAP setup plist");
    return plist;
}

static NSURL *PublicURL(id value, NSString *host) {
    if (![value isKindOfClass:[NSString class]]) throw std::runtime_error("Missing public SAP URL");
    NSURL *url = [NSURL URLWithString:value];
    if (![url.scheme isEqualToString:@"https"] || ![url.host.lowercaseString isEqualToString:host] || url.user || url.password || url.fragment || (url.port && url.port.intValue != 443))
        throw std::runtime_error("Invalid public SAP URL");
    return url;
}

static void Require(BOOL success, NSError *error, const char *stage) {
    if (success) {
        std::cout << "SAP " << stage << " passed." << std::endl;
        return;
    }
    // This harness handles public setup only; the engine exception contains no account data.
    throw std::runtime_error(std::string(stage) + ": " + (error.localizedDescription.UTF8String ?: "unknown failure"));
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        try {
            if (argc != 2) throw std::runtime_error("Supply verified SAPAssets directory");
            NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
            configuration.timeoutIntervalForRequest = 30;
            configuration.timeoutIntervalForResource = 60;
            configuration.URLCredentialStorage = nil;
            configuration.HTTPCookieStorage = nil;
            NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
            NSDictionary *bag = FetchPlist(session, [NSURL URLWithString:@"https://init.itunes.apple.com/bag.xml?guid=024153535050"]);
            NSDictionary *nested = bag[@"urlBag"] ?: @{};
            NSURL *certURL = PublicURL(bag[@"sign-sap-setup-cert"] ?: nested[@"sign-sap-setup-cert"], @"s.mzstatic.com");
            NSURL *setupURL = PublicURL(bag[@"sign-sap-setup"] ?: nested[@"sign-sap-setup"], @"fpinit.itunes.apple.com");
            const uint8_t hardware[] = {2, 0x41, 0x53, 0x53, 0x50, 0x50};
            NSError *error = nil;
            SAPContext *signer = [[SAPContext alloc] initWithAssetsURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]] hardwareID:[NSData dataWithBytes:hardware length:sizeof(hardware)] error:&error];
            Require(signer != nil, error, "initialize");
            NSData *cert = FetchPlist(session, certURL)[@"sign-sap-setup-cert"];
            if (![cert isKindOfClass:[NSData class]]) throw std::runtime_error("Missing SAP certificate");
            NSData *exchange = [signer exchangeData:cert version:200 error:&error];
            Require(exchange != nil, error, "exchange-1");
            NSData *reply = FetchPlist(session, setupURL, @{@"sign-sap-setup-buffer": exchange})[@"sign-sap-setup-buffer"];
            if (![reply isKindOfClass:[NSData class]]) throw std::runtime_error("Missing SAP setup reply");
            NSData *output = [signer exchangeData:reply version:200 error:&error];
            Require(output != nil && signer.complete, error, "exchange-2");
            NSData *body = [NSPropertyListSerialization dataWithPropertyList:@{@"sap-test": @"public-setup-only"} format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
            for (int attempt = 0; attempt < 3; ++attempt) {
                NSData *signature = [signer signData:body error:&error];
                Require(signature.length > 0, error, "sign");
                std::cout << "Signature length: " << signature.length << " bytes." << std::endl;
            }
            [session invalidateAndCancel];
            std::cout << "Public SAP handshake and repeated signing passed (no credentials)." << std::endl;
            return 0;
        } catch (const std::exception &error) {
            std::cerr << "Public SAP check failed: " << error.what() << std::endl;
            return 1;
        }
    }
}
