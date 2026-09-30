#import <Foundation/Foundation.h>
#include "SapMachine.h"
#include <unicorn/unicorn.h>
#include <iostream>
#include <stdexcept>

// Standalone diagnostic binary only; replay controlled Web fixture entropy.
static NSArray *events;
static NSUInteger cursor;
static NSUInteger timestampRemaining;
static uint64_t timestampCount;
static uint64_t NextEvent(NSString *kind) {
    if ([kind isEqual:@"tsc"] && timestampRemaining) {
        --timestampRemaining;
        return 1234567890 + timestampCount++ * 10000;
    }
    if (cursor >= events.count || ![events[cursor][0] isEqual:kind])
        throw std::runtime_error("Web/native entropy call sequence differs");
    if ([kind isEqual:@"tsc"]) {
        timestampRemaining = [events[cursor++][1] unsignedLongLongValue] - 1;
        return 1234567890 + timestampCount++ * 10000;
    }
    return [events[cursor++][1] unsignedLongLongValue];
}
uint32_t SAPReplayRandom() { return static_cast<uint32_t>(NextEvent(@"random")); }
int64_t SAPReplayTime() { return static_cast<int64_t>(NextEvent(@"time")); }
bool SAPReplayTimestamp(uc_engine *engine, void *) {
    uint64_t value = NextEvent(@"tsc"), zero = 0;
    if (uc_reg_write(engine, UC_X86_REG_RAX, &value) != UC_ERR_OK ||
        uc_reg_write(engine, UC_X86_REG_RDX, &zero) != UC_ERR_OK)
        throw std::runtime_error("Cannot control fixture timestamp");
    return true;
}
bool SAPReplayTimestampP(uc_engine *engine, void *data) {
    SAPReplayTimestamp(engine, data);
    uint64_t zero = 0;
    if (uc_reg_write(engine, UC_X86_REG_RCX, &zero) != UC_ERR_OK)
        throw std::runtime_error("Cannot control fixture timestamp auxiliary register");
    return true;
}
static void TimestampInstruction(uc_engine *engine, uint64_t address, uint32_t size, void *) {
    uint8_t bytes[3] = {};
    if (uc_mem_read(engine, address, bytes, 3) != UC_ERR_OK)
        throw std::runtime_error("Cannot read fixture instruction");
    if (size == 2 && bytes[0] == 0x0f && bytes[1] == 0x31) {
        SAPReplayTimestamp(engine, nullptr);
    } else if (size == 3 && bytes[0] == 0x0f && bytes[1] == 1 && bytes[2] == 0xf9) {
        SAPReplayTimestampP(engine, nullptr);
    } else return;
    const uint64_t next = address + size;
    if (uc_reg_write(engine, UC_X86_REG_RIP, &next) != UC_ERR_OK)
        throw std::runtime_error("Cannot advance fixture timestamp instruction");
}
void SAPInstallTimestampHooks(uc_engine *engine) {
    uc_mem_region *regions;
    uint32_t count;
    if (uc_mem_regions(engine, &regions, &count) != UC_ERR_OK)
        throw std::runtime_error("Cannot inspect fixture image regions");
    size_t candidates = 0;
    for (uint32_t i = 0; i < count; ++i) {
        if (regions[i].begin < 0x100000000000 || regions[i].begin >= 0x100100000000) continue;
        std::vector<uint8_t> data(regions[i].end - regions[i].begin + 1);
        if (uc_mem_read(engine, regions[i].begin, data.data(), data.size()) != UC_ERR_OK)
            throw std::runtime_error("Cannot read fixture image");
        for (size_t offset = 0; offset + 2 < data.size(); ++offset) {
            if (data[offset] != 0x0f || (data[offset + 1] != 0x31 &&
                !(data[offset + 1] == 1 && data[offset + 2] == 0xf9))) continue;
            const uint64_t address = regions[i].begin + offset;
            uc_hook hook;
            if (uc_hook_add(engine, &hook, UC_HOOK_CODE, reinterpret_cast<void *>(TimestampInstruction), nullptr, address, address) != UC_ERR_OK)
                throw std::runtime_error("Cannot install fixture timestamp hook");
            ++candidates;
        }
    }
    uc_free(regions);
    std::cout << "Native timestamp candidates: " << candidates << std::endl;
}

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
            if (cursor != events.count || timestampRemaining) throw std::runtime_error("Unused Web entropy events");
            std::cout << "Web/native SAP equivalence passed: public handshake and synthetic body only." << std::endl;
            return 0;
        } catch (const std::exception& error) {
            std::cerr << "SAP equivalence failed: " << error.what() << std::endl;
            return 1;
        }
    }
}
