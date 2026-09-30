#import <Foundation/Foundation.h>
#include "SapMachine.h"
#include <iostream>
#include <stdexcept>

// Standalone diagnostic binary only; replay controlled Web fixture entropy.
static NSArray *events;
static NSUInteger cursor;
static uint64_t NextEvent(NSString *kind) {
    if (cursor >= events.count || ![events[cursor][0] isEqual:kind])
        throw std::runtime_error("Web/native entropy call sequence differs");
    return [events[cursor++][1] unsignedLongLongValue];
}
uint32_t SAPReplayRandom() { return static_cast<uint32_t>(NextEvent(@"random")); }
int64_t SAPReplayTime() { return static_cast<int64_t>(NextEvent(@"time")); }

static std::vector<uint8_t> Decode(NSString *value) {
    NSData *data = [[NSData alloc] initWithBase64EncodedString:value options:0];
    if (!data) throw std::runtime_error("Invalid fixture base64");
    const auto *bytes = static_cast<const uint8_t *>(data.bytes);
    return {bytes, bytes + data.length};
}
static std::vector<uint8_t> Read(NSString *root, NSString *name) {
    NSData *data = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:name]];
    if (!data) throw std::runtime_error("Missing verified SAP asset");
    const auto *bytes = static_cast<const uint8_t *>(data.bytes);
    return {bytes, bytes + data.length};
}
static void Match(const std::vector<uint8_t>& native, const std::vector<uint8_t>& web, const char *stage) {
    if (native != web) {
        size_t offset = 0;
        while (offset < native.size() && offset < web.size() && native[offset] == web[offset]) ++offset;
        std::cerr << stage << " differs: native=" << native.size() << ", web=" << web.size() << ", first differing offset=" << offset << std::endl;
        throw std::runtime_error("Web/native SAP byte comparison failed");
    }
    std::cout << "Web/native " << stage << " matches (" << native.size() << " bytes)." << std::endl;
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        try {
            if (argc != 3) throw std::runtime_error("Supply verified SAP assets and Web fixture");
            NSString *root = [NSString stringWithUTF8String:argv[1]];
            NSDictionary *fixture = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[2]]] options:0 error:nil];
            if (!fixture) throw std::runtime_error("Missing Web fixture");
            events = fixture[@"events"];
            auto machine = SapMachine::Create(Read(root, @"CoreFP"), Read(root, @"CommerceCore"), Read(root, @"CommerceKit"), Read(root, @"CoreFP.icxs"));
            auto hardware = Decode(fixture[@"hardware"]);
            auto context = machine->Initialize(hardware);
            auto [first, state] = machine->Exchange(200, hardware, context, Decode(fixture[@"certificate"]));
            if (state != 1) throw std::runtime_error("Invalid first exchange state");
            Match(first, Decode(fixture[@"first"]), "setup request");
            auto [second, complete] = machine->Exchange(200, hardware, context, Decode(fixture[@"reply"]));
            if (complete != 0) throw std::runtime_error("Invalid second exchange state");
            auto body = Decode(fixture[@"body"]);
            for (NSString *signature in fixture[@"signatures"])
                Match(machine->Sign(context, body), Decode(signature), "signature");
            if (cursor != events.count) throw std::runtime_error("Unused Web entropy events");
            machine->Teardown(context);
            std::cout << "Web/native SAP equivalence passed: public handshake and synthetic body only." << std::endl;
            return 0;
        } catch (const std::exception& error) {
            std::cerr << "SAP equivalence failed: " << error.what() << std::endl;
            return 1;
        }
    }
}
