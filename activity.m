// Optional native Discord IPC activity. The Windows stream remains opaque.
#import <Foundation/Foundation.h>
#include "activity.h"
#include <errno.h>
#include <libkern/OSByteOrder.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static NSString *client_id;
static NSString *game_title;
static NSNumber *started;
static int fd = -1;
static bool published;
static double retry_at, ready_deadline;
static unsigned char input[65536];
static size_t used;

static NSString *environment(const char *key)
{
    const char *value = getenv(key);
    return value ? [NSString stringWithUTF8String:value] : nil;
}

static bool digits(NSString *value)
{
    return value.length > 0 && value.length <= 20 &&
           [value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location == NSNotFound;
}

static NSString *read_text(NSString *path, NSUInteger limit)
{
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:path];
    NSData *data = [file readDataUpToLength:limit + 1 error:NULL];
    [file closeFile];
    if (data.length > limit) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

void activity_init(const char *host_path)
{
    @autoreleasepool {
        if (![environment("NOTPROTON_DISCORD_BASIC_ACTIVITY") isEqualToString:@"1"]) return;
        NSString *directory = [[NSString stringWithUTF8String:host_path] stringByDeletingLastPathComponent];
        NSString *config = [directory stringByAppendingPathComponent:@"activity-client-id"];
        client_id = [read_text(config, 128) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!digits(client_id)) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:config])
                fprintf(stderr, "NotProton Discord: invalid activity-client-id, using the bundled Application ID\n");
            client_id = @"1569701971353534514";
        }

        NSString *install = [environment("STEAM_COMPAT_INSTALL_PATH") stringByStandardizingPath];
        if (install.length == 0 || !install.isAbsolutePath) {
            client_id = nil;
            return;
        }
        game_title = install.lastPathComponent;
        NSString *app_id = environment("SteamAppId");
        if (digits(app_id)) {
            NSString *steamapps = install.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
            NSString *manifest = [steamapps stringByAppendingPathComponent:[NSString stringWithFormat:@"appmanifest_%@.acf", app_id]];
            NSString *vdf = read_text(manifest, 1024 * 1024);
            if (vdf.length) {
                NSRegularExpression *name = [NSRegularExpression regularExpressionWithPattern:@"(?m)^\\s*\"name\"[ \\t]+\"([^\"\\r\\n]+)\"" options:0 error:NULL];
                NSTextCheckingResult *match = [name firstMatchInString:vdf options:0 range:NSMakeRange(0, vdf.length)];
                if (match) game_title = [vdf substringWithRange:[match rangeAtIndex:1]];
            }
        }
        if (game_title.length > 128) {
            NSRange last = [game_title rangeOfComposedCharacterSequenceAtIndex:127];
            game_title = [game_title substringToIndex:last.location];
        }
        started = @(time(NULL));
    }
}

static bool send_frame(uint32_t opcode, NSData *payload)
{
    if (!payload || payload.length > sizeof(input) - 8) return false;
    uint32_t header[] = {OSSwapHostToLittleInt32(opcode), OSSwapHostToLittleInt32((uint32_t)payload.length)};
    NSMutableData *frame = [NSMutableData dataWithBytes:header length:sizeof(header)];
    [frame appendData:payload];
    return send(fd, frame.bytes, frame.length, 0) == (ssize_t)frame.length;
}

static bool send_json(uint32_t opcode, NSDictionary *body)
{
    return send_frame(opcode, [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL]);
}

static bool set_activity(bool active)
{
    id value = active ? @{@"details": game_title, @"timestamps": @{@"start": started}} : NSNull.null;
    return send_json(1, @{@"cmd": @"SET_ACTIVITY",
                          @"nonce": active ? @"activity" : @"clear",
                          @"args": @{@"pid": @(getpid()), @"activity": value}});
}

static void disconnect(void)
{
    if (fd >= 0) close(fd);
    fd = -1;
    published = false;
    used = 0;
}

void activity_clear(void)
{
    @autoreleasepool {
        if (published) set_activity(false);
        disconnect();
    }
}

static bool handle_frame(uint32_t opcode, NSData *payload)
{
    if (opcode == 2) return false;
    if (opcode == 3) return send_frame(4, payload);
    if (opcode != 1) return true;
    id body = [NSJSONSerialization JSONObjectWithData:payload options:0 error:NULL];
    if (![body isKindOfClass:NSDictionary.class]) return false;
    if ([body[@"evt"] isEqual:@"ERROR"]) return false;
    if (!published && [body[@"evt"] isEqual:@"READY"]) {
        if (!set_activity(true)) return false;
        published = true;
    }
    return true;
}

static bool read_frames(void)
{
    ssize_t count = recv(fd, input + used, sizeof(input) - used, 0);
    if (count < 0) return errno == EAGAIN || errno == EINTR;
    if (!count) return false;
    used += (size_t)count;
    size_t offset = 0;
    while (used - offset >= 8) {
        uint32_t header[2];
        memcpy(header, input + offset, sizeof(header));
        uint32_t length = OSSwapLittleToHostInt32(header[1]);
        if (length > sizeof(input) - 8) return false;
        if (length > used - offset - 8) break;
        NSData *body = [NSData dataWithBytes:input + offset + 8 length:length];
        if (!handle_frame(OSSwapLittleToHostInt32(header[0]), body)) return false;
        offset += 8 + length;
    }
    if (offset) {
        used -= offset;
        memmove(input, input + offset, used);
    }
    return true;
}

void activity_tick(double now, bool game_connected, int (*connect_socket)(void))
{
    if (!client_id) return;
    @autoreleasepool {
        if (game_connected) {
            retry_at = now + 0.5;
            return;
        }
        if (fd >= 0) {
            if ((published || now < ready_deadline) && read_frames()) return;
            disconnect();
            retry_at = now + 2;
        }
        if (now < retry_at) return;
        fd = connect_socket();
        if (fd >= 0 && send_json(0, @{@"v": @1, @"client_id": client_id})) {
            ready_deadline = now + 2;
        } else {
            disconnect();
            retry_at = now + 2;
        }
    }
}
