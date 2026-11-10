#import "../activity.m"
#include <assert.h>

int main(void)
{
    @autoreleasepool {
        NSURLRequest *request = grid_request(@"282800", @"test-key");
        assert([request.URL.absoluteString isEqual:
            @"https://www.steamgriddb.com/api/v2/icons/steam/282800?nsfw=false&humor=false"]);
        assert([[request valueForHTTPHeaderField:@"Authorization"] isEqual:@"Bearer test-key"]);
        assert(!grid_request(@"282800", @"test\nkey"));
        NSData *result = [@"{\"success\":true,\"data\":[null,{\"url\":\"http://example.org/icon\"},"
                           "{\"url\":\"https://cdn.steamgriddb.com/icon/test.png\"}]}"
            dataUsingEncoding:NSUTF8StringEncoding];
        assert([grid_response_icon(result) isEqual:@"https://cdn.steamgriddb.com/icon/test.png"]);
        assert(!grid_response_icon([@"{\"success\":false,\"data\":[]}" dataUsingEncoding:NSUTF8StringEncoding]));
        assert(!grid_response_icon([@"[]" dataUsingEncoding:NSUTF8StringEncoding]));
    }
}
