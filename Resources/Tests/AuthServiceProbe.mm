#import <Foundation/Foundation.h>
#import "SAPContext.h"
#import "CurlAuthenticationClient.h"
#include <iostream>
#include <stdexcept>

// One deliberately nonexistent account; no real credentials or response bodies.
static NSString *const UserAgent = @"Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6";
static id DecodePlist(NSData *data) {
    id value = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
    if (value) return value;
    // Apple's public bag can wrap the plist; mirror production StoreProtocol.
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) return nil;
    NSRange begin = [text rangeOfString:@"<plist"];
    NSRange end = [text rangeOfString:@"</plist>"];
    if (begin.location == NSNotFound || end.location == NSNotFound || end.location <= begin.location) return nil;
    NSData *inner = [[text substringWithRange:NSMakeRange(begin.location, NSMaxRange(end) - begin.location)] dataUsingEncoding:NSUTF8StringEncoding];
    return [NSPropertyListSerialization propertyListWithData:inner options:0 format:NULL error:NULL];
}
static CurlAuthenticationResponse *Fetch(NSString *ca, NSURL *url, NSData *body, NSString *signature, const char *stage) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:UserAgent forHTTPHeaderField:@"User-Agent"];
    if (body) {
        request.HTTPMethod = @"POST";
        request.HTTPBody = body;
        [request setValue:signature ? @"application/x-apple-plist" : @"application/x-plist" forHTTPHeaderField:@"Content-Type"];
    }
    if (signature) [request setValue:signature forHTTPHeaderField:@"X-Apple-ActionSignature"];
    NSError *error = nil;
    CurlAuthenticationResponse *response = [[CurlAuthenticationClient new] performRequest:request caBundlePath:ca error:&error];
    if (!response) throw std::runtime_error("Probe TLS transfer failed");
    const BOOL plist = DecodePlist(response.data) != nil;
    std::cout << stage << ": HTTP " << response.statusCode << ", " << response.data.length << " bytes, plist=" << (plist ? "true" : "false") << std::endl;
    return response;
}

static NSDictionary *Plist(CurlAuthenticationResponse *response) {
    id value = DecodePlist(response.data);
    if (response.statusCode != 200 || ![value isKindOfClass:[NSDictionary class]]) throw std::runtime_error("Invalid public setup response");
    return value;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        try {
            if (argc != 3) throw std::runtime_error("Supply packed SAP assets and CA bundle");
            NSString *ca = [NSString stringWithUTF8String:argv[2]];
            NSString *guid = @"024153535050";
            std::cout << "Native live probe: " << CurlAuthenticationClient.runtimeDescription.UTF8String << std::endl;
            NSDictionary *bag = Plist(Fetch(ca, [NSURL URLWithString:@"https://init.itunes.apple.com/bag.xml?guid=024153535050"], nil, nil, "bag"));
            NSDictionary *nested = bag[@"urlBag"] ?: @{};
            NSString *certText = bag[@"sign-sap-setup-cert"] ?: nested[@"sign-sap-setup-cert"];
            NSString *setupText = bag[@"sign-sap-setup"] ?: nested[@"sign-sap-setup"];
            NSURL *certURL = [NSURL URLWithString:certText];
            NSURL *setupURL = [NSURL URLWithString:setupText];
            if (![certURL.host isEqualToString:@"s.mzstatic.com"] || ![setupURL.host isEqualToString:@"fpinit.itunes.apple.com"] || ![certURL.scheme isEqualToString:@"https"] || ![setupURL.scheme isEqualToString:@"https"]) throw std::runtime_error("Invalid public endpoints");
            NSError *error = nil;
            SAPContext *signer = [[SAPContext alloc] initWithAssetsURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]] hardwareID:[guid dataUsingEncoding:NSUTF8StringEncoding] error:&error];
            if (!signer) throw std::runtime_error("SAP initialize failed");
            NSData *certificate = Plist(Fetch(ca, certURL, nil, nil, "certificate"))[@"sign-sap-setup-cert"];
            NSData *first = [signer exchangeData:certificate version:200 error:&error];
            if (!first) throw std::runtime_error("SAP first exchange failed");
            NSData *envelope = [NSPropertyListSerialization dataWithPropertyList:@{@"sign-sap-setup-buffer":first} format:NSPropertyListXMLFormat_v1_0 options:0 error:&error];
            NSData *reply = Plist(Fetch(ca, setupURL, envelope, nil, "setup"))[@"sign-sap-setup-buffer"];
            if (![signer exchangeData:reply version:200 error:&error] || !signer.complete) throw std::runtime_error("SAP completion failed");
            NSString *xml = @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict><key>appleId</key><string>fixture@example.invalid</string><key>attempt</key><string>4</string><key>guid</key><string>024153535050</string><key>password</key><string>synthetic-test-only</string><key>rmp</key><string>0</string><key>why</key><string>signIn</string></dict>\n</plist>";
            NSData *body = [xml dataUsingEncoding:NSUTF8StringEncoding];
            NSData *signature = [signer signData:body error:&error];
            if (signature.length != 501) throw std::runtime_error("Unexpected signature length");
            NSURL *url = [NSURL URLWithString:@"https://auth.itunes.apple.com/auth/v1/native/fast/?guid=024153535050"];
            CurlAuthenticationResponse *response = Fetch(ca, url, body, [signature base64EncodedStringWithOptions:0], "synthetic-login");
            NSDictionary *result = DecodePlist(response.data);
            if ([result isKindOfClass:[NSDictionary class]]) {
                const BOOL explicitRejection = result[@"failureType"] != nil || result[@"customerMessage"] != nil || result[@"dialog"] != nil;
                std::cout << "Explicit structured rejection=" << (explicitRejection ? "true" : "false") << std::endl;
            }
            std::cout << "Completed one synthetic login probe; actual account acceptance remains untested." << std::endl;
            return 0;
        } catch (const std::exception &error) {
            std::cerr << error.what() << std::endl;
            return 1;
        }
    }
}
