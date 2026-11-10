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
static NSString *game_icon;
static NSNumber *started;
static int fd = -1;
static bool published;
static bool use_activity_name = true;
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

// Steam's binary shortcut file nests numbered records under "shortcuts".
static NSString *shortcut_record(const unsigned char **cursor, const unsigned char *end,
                                 uint32_t wanted, unsigned depth)
{
    NSString *title = nil;
    uint32_t id = 0;
    while (*cursor < end) {
        unsigned type = *(*cursor)++;
        if (type == 8) return depth == 2 && id == wanted ? title : nil;
        const unsigned char *key = *cursor;
        const unsigned char *zero = memchr(key, 0, end - key);
        if (!zero) break;
        *cursor = zero + 1;
        if (type == 0 && depth < 8) {
            NSString *match = shortcut_record(cursor, end, wanted, depth + 1);
            if (match.length) return match;
        } else if (type == 1) {
            const unsigned char *value = *cursor;
            zero = memchr(value, 0, end - value);
            if (!zero) break;
            if (depth == 2 && !strcasecmp((const char *)key, "appname"))
                title = [[NSString alloc] initWithBytes:value length:zero - value encoding:NSUTF8StringEncoding];
            *cursor = zero + 1;
        } else if (type == 2 && end - *cursor >= 4) {
            if (depth == 2 && !strcasecmp((const char *)key, "appid")) {
                memcpy(&id, *cursor, sizeof(id));
                id = OSSwapLittleToHostInt32(id);
            }
            *cursor += 4;
        } else break;
    }
    *cursor = end;
    return nil;
}

static NSString *steam_root(void)
{
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *steam = [environment("STEAM_COMPAT_CLIENT_INSTALL_PATH") stringByStandardizingPath];
    for (unsigned level = 0; steam.isAbsolutePath && level < 8; ++level) {
        if ([files fileExistsAtPath:[steam stringByAppendingPathComponent:@"userdata"]] ||
            [files fileExistsAtPath:[steam stringByAppendingPathComponent:@"appcache"]]) return steam;
        steam = steam.stringByDeletingLastPathComponent;
    }
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Steam"];
}

static uint32_t shortcut_id(void)
{
    NSString *game_id = environment("SteamGameId");
    if (!digits(game_id)) return 0;
    errno = 0;
    uint64_t id = strtoull(game_id.UTF8String, NULL, 10);
    return !errno && (uint32_t)id == 0x02000000 ? (uint32_t)(id >> 32) : 0;
}

static NSString *shortcut_title(NSString *steam, uint32_t id)
{
    if (!id) return nil;
    NSString *userdata = [steam stringByAppendingPathComponent:@"userdata"];
    NSArray<NSString *> *accounts = [NSFileManager.defaultManager contentsOfDirectoryAtPath:userdata error:NULL];
    for (NSString *account in accounts) {
        if (!digits(account)) continue;
        NSString *config = [[userdata stringByAppendingPathComponent:account]
            stringByAppendingPathComponent:@"config/shortcuts.vdf"];
        NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:config];
        NSData *data = [file readDataUpToLength:4 * 1024 * 1024 + 1 error:NULL];
        [file closeFile];
        if (!data.length || data.length > 4 * 1024 * 1024) continue;
        const unsigned char *cursor = data.bytes;
        NSString *title = shortcut_record(&cursor, cursor + data.length, id, 0);
        if (title.length) return title;
    }
    return nil;
}

static NSString *find_game_icon(NSString *directory, NSString *steam, NSString *app_id, bool shortcut)
{
    if (shortcut || !digits(app_id)) return nil;
    NSString *override = [[directory stringByAppendingPathComponent:@"activity-icons"]
        stringByAppendingPathComponent:app_id];
    NSString *icon = [read_text(override, 1024) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (icon.length && icon.length <= 300 &&
        [icon rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound) {
        NSURLComponents *url = [NSURLComponents componentsWithString:icon];
        if (([url.scheme.lowercaseString isEqual:@"https"] && url.host.length && !url.user && !url.password) ||
            [icon rangeOfString:@"^[a-zA-Z0-9_-]+$" options:NSRegularExpressionSearch].location != NSNotFound)
            return icon;
    }
    NSString *cache = [[steam stringByAppendingPathComponent:@"appcache/librarycache"] stringByAppendingPathComponent:app_id];
    NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:cache error:NULL];
    for (NSString *entry in [entries sortedArrayUsingSelector:@selector(compare:)]) {
        if ([entry rangeOfString:@"^[0-9a-f]{40}\\.jpg$" options:NSRegularExpressionSearch].location != NSNotFound)
            return [NSString stringWithFormat:@"https://shared.fastly.steamstatic.com/community_assets/images/apps/%@/%@", app_id, entry];
    }
    return [NSString stringWithFormat:@"https://cdn.cloudflare.steamstatic.com/steam/apps/%@/header.jpg", app_id];
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
        NSString *steam = steam_root();
        uint32_t shortcut = shortcut_id();
        game_title = shortcut_title(steam, shortcut);
        NSString *app_id = environment("SteamAppId");
        if (!game_title && install.isAbsolutePath && digits(app_id)) {
            NSString *steamapps = install.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
            NSString *manifest = [steamapps stringByAppendingPathComponent:[NSString stringWithFormat:@"appmanifest_%@.acf", app_id]];
            NSString *vdf = read_text(manifest, 1024 * 1024);
            if (vdf.length) {
                NSRegularExpression *name = [NSRegularExpression regularExpressionWithPattern:@"(?m)^\\s*\"name\"[ \\t]+\"([^\"\\r\\n]+)\"" options:0 error:NULL];
                NSTextCheckingResult *match = [name firstMatchInString:vdf options:0 range:NSMakeRange(0, vdf.length)];
                if (match) game_title = [vdf substringWithRange:[match rangeAtIndex:1]];
            }
        }
        if (!game_title && install.isAbsolutePath)
            game_title = [install.lastPathComponent stringByReplacingOccurrencesOfString:@"_" withString:@" "];
        if (!game_title.length) {
            client_id = nil;
            return;
        }
        if (game_title.length > 128) {
            NSRange last = [game_title rangeOfComposedCharacterSequenceAtIndex:127];
            game_title = [game_title substringToIndex:last.location];
        }
        NSString *icon_id = shortcut ? [NSString stringWithFormat:@"%u", shortcut] : app_id;
        game_icon = find_game_icon(directory, steam, icon_id, shortcut != 0);
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
    NSMutableDictionary *activity = [@{@"timestamps": @{@"start": started}} mutableCopy];
    activity[use_activity_name ? @"name" : @"details"] = game_title;
    if (game_icon) activity[@"assets"] = @{@"large_image": game_icon, @"large_text": game_title};
    id value = active ? activity : NSNull.null;
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
    if ([body[@"evt"] isEqual:@"ERROR"]) {
        if (published && [body[@"nonce"] isEqual:@"activity"] && (use_activity_name || game_icon)) {
            if (game_icon) game_icon = nil;
            else use_activity_name = false;
            return set_activity(true);
        }
        return false;
    }
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
