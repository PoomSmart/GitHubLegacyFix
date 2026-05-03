#import <Foundation/Foundation.h>
#import <HBLog.h>

static NSString *removeFragmentDefinition(NSString *query, NSString *fragmentName) {
    NSString *marker = [NSString stringWithFormat:@"fragment %@ on ", fragmentName];
    NSRange markerRange = [query rangeOfString:marker];
    if (markerRange.location == NSNotFound) return query;

    NSUInteger openBrace = NSNotFound;
    for (NSUInteger i = markerRange.location; i < query.length; i++) {
        if ([query characterAtIndex:i] == '{') {
            openBrace = i;
            break;
        }
    }
    if (openBrace == NSNotFound) return query;

    NSInteger depth = 0;
    NSUInteger closeBrace = NSNotFound;
    for (NSUInteger i = openBrace; i < query.length; i++) {
        unichar c = [query characterAtIndex:i];
        if (c == '{') {
            depth++;
        } else if (c == '}') {
            depth--;
            if (depth == 0) {
                closeBrace = i;
                break;
            }
        }
    }
    if (closeBrace == NSNotFound) return query;

    NSMutableString *result = [query mutableCopy];
    NSRange removeRange = NSMakeRange(markerRange.location,
                                      closeBrace - markerRange.location + 1);
    if (removeRange.location + removeRange.length < result.length &&
        [result characterAtIndex:removeRange.location + removeRange.length] == ' ') {
        removeRange.length++;
    }
    [result replaceCharactersInRange:removeRange withString:@""];
    return [result copy];
}

// Remove a field (and its argument list + body) from a query string, e.g. `projectsNext(…) { … }`.
// The marker is the field name; everything from the marker up to (and including) the matching
// closing brace is deleted. Handles arbitrary nesting.
static NSString *removeFieldBlock(NSString *query, NSString *fieldName) {
    NSRange markerRange = [query rangeOfString:fieldName];
    if (markerRange.location == NSNotFound) return query;

    NSUInteger openBrace = NSNotFound;
    for (NSUInteger i = markerRange.location; i < query.length; i++) {
        unichar c = [query characterAtIndex:i];
        if (c == '{') { openBrace = i; break; }
        // If we hit another field or closing brace before an open brace, bail.
        if (c == '}') return query;
    }
    if (openBrace == NSNotFound) return query;

    NSInteger depth = 0;
    NSUInteger closeBrace = NSNotFound;
    for (NSUInteger i = openBrace; i < query.length; i++) {
        unichar c = [query characterAtIndex:i];
        if (c == '{') depth++;
        else if (c == '}') { depth--; if (depth == 0) { closeBrace = i; break; } }
    }
    if (closeBrace == NSNotFound) return query;

    NSMutableString *result = [query mutableCopy];
    NSRange removeRange = NSMakeRange(markerRange.location, closeBrace - markerRange.location + 1);
    if (removeRange.location + removeRange.length < result.length &&
        [result characterAtIndex:removeRange.location + removeRange.length] == ' ') {
        removeRange.length++;
    }
    [result replaceCharactersInRange:removeRange withString:@""];
    return [result copy];
}

static BOOL isGitHubGraphQLRequest(NSURLRequest *request) {
    return [request.URL.host isEqualToString:@"api.github.com"] &&
           [request.URL.path isEqualToString:@"/graphql"] &&
           [@"POST" isEqualToString:request.HTTPMethod];
}

static NSData *patchedBodyForGraphQLRequest(NSData *body) {
    if (body.length == 0) return body;

    NSError *err = nil;
    id json = [NSJSONSerialization JSONObjectWithData:body
                                             options:NSJSONReadingMutableContainers
                                               error:&err];
    if (err || ![json isKindOfClass:[NSMutableDictionary class]]) return body;

    NSMutableDictionary *dict = (NSMutableDictionary *)json;
    NSString *query = dict[@"query"];
    if (![query isKindOfClass:[NSString class]]) return body;

    if (![query containsString:@"projectCards"] && ![query containsString:@"renderMobileTasklistBlocks"]
        && ![query containsString:@"projectNextItems"] && ![query containsString:@"projectsNext"]) {
        return body;
    }

    NSMutableString *q = [query mutableCopy];
    // `renderMobileTasklistBlocks: true` — removed argument on bodyHTML(); no longer in schema.
    [q replaceOccurrencesOfString:@" renderMobileTasklistBlocks: true"
                       withString:@""
                          options:0
                            range:NSMakeRange(0, q.length)];
    // Remove fragment spreads; the fragments themselves reference `projectCards`,
    // which GitHub removed in favour of projectItems (Projects V2).
    [q replaceOccurrencesOfString:@" ...IssueProjectCardFragment"
                       withString:@""
                          options:0
                            range:NSMakeRange(0, q.length)];
    [q replaceOccurrencesOfString:@" ...PullRequestProjectCardFragment"
                       withString:@""
                          options:0
                            range:NSMakeRange(0, q.length)];
    // `projectNextItems` — older Projects V2 Next API, also removed from schema.
    [q replaceOccurrencesOfString:@" ...IssueProjectNextItemsFragment"
                       withString:@""
                          options:0
                            range:NSMakeRange(0, q.length)];
    [q replaceOccurrencesOfString:@" ...PullRequestProjectNextItemsFragment"
                       withString:@""
                          options:0
                            range:NSMakeRange(0, q.length)];
    // `projectsNext` field on User — also removed from schema (Projects V2 Next).
    NSString *q2 = removeFieldBlock(q, @"projectsNext");
    NSString *cleaned = removeFragmentDefinition(q2, @"IssueProjectCardFragment");
    cleaned = removeFragmentDefinition(cleaned, @"PullRequestProjectCardFragment");
    // ProjectProgressFieldsFragment is only referenced by the two fragments above;
    // orphaned fragment definitions are rejected by GitHub's schema validator.
    cleaned = removeFragmentDefinition(cleaned, @"ProjectProgressFieldsFragment");
    // ProjectNext* fragment definitions for the removed projectNextItems field.
    cleaned = removeFragmentDefinition(cleaned, @"IssueProjectNextItemsFragment");
    cleaned = removeFragmentDefinition(cleaned, @"PullRequestProjectNextItemsFragment");
    cleaned = removeFragmentDefinition(cleaned, @"ProjectNextItemConnectionFragment");
    cleaned = removeFragmentDefinition(cleaned, @"ProjectNextItemFragment");
    cleaned = removeFragmentDefinition(cleaned, @"ProjectNextFieldConstraintFragment");
    cleaned = removeFragmentDefinition(cleaned, @"ProjectNextFieldConstraintIterations");

    if ([cleaned isEqualToString:query]) return body;

    dict[@"query"] = cleaned;

    NSData *newBody = [NSJSONSerialization dataWithJSONObject:dict options:0 error:&err];
    return (!err && newBody) ? newBody : body;
}

static BOOL injectRemovedFieldStubs(id node) {
    if ([node isKindOfClass:[NSMutableDictionary class]]) {
        NSMutableDictionary *dict = (NSMutableDictionary *)node;
        BOOL modified = NO;
        NSString *typeName = dict[@"__typename"];
        if (([typeName isEqualToString:@"Issue"] || [typeName isEqualToString:@"PullRequest"])
            && !dict[@"projectCards"]) {
            // Apollo's GraphQLSelectionSetMapper validates every field in __selections
            // (including __typename) at parse time. The stub must satisfy all fields
            // expected by IssueProjectCardFragment.ProjectCards.__selections:
            //   __typename, nodes, totalCount, pageInfo { __typename, hasNextPage,
            //   hasPreviousPage, startCursor, endCursor }
            NSMutableDictionary *stub = [NSMutableDictionary dictionaryWithDictionary:@{
                @"__typename": @"ProjectCardConnection",
                @"nodes": [NSMutableArray array],
                @"totalCount": @0,
                @"pageInfo": [NSMutableDictionary dictionaryWithDictionary:@{
                    @"__typename": @"PageInfo",
                    @"hasNextPage": @NO,
                    @"hasPreviousPage": @NO,
                    @"startCursor": [NSNull null],
                    @"endCursor": [NSNull null]
                }]
            }];
            dict[@"projectCards"] = stub;
            HBLogDebug(@"[GitHubLegacyFix] Injected stub projectCards for __typename=%@", typeName);
            modified = YES;
        }
        // projectNextItems — older Projects V2 Next API (1.78.0 era), same treatment.
        if (([typeName isEqualToString:@"Issue"] || [typeName isEqualToString:@"PullRequest"])
            && !dict[@"projectNextItems"]) {
            NSMutableDictionary *stub = [NSMutableDictionary dictionaryWithDictionary:@{
                @"__typename": @"ProjectNextItemConnection",
                @"nodes": [NSMutableArray array],
                @"totalCount": @0,
                @"pageInfo": [NSMutableDictionary dictionaryWithDictionary:@{
                    @"__typename": @"PageInfo",
                    @"hasNextPage": @NO,
                    @"hasPreviousPage": @NO,
                    @"startCursor": [NSNull null],
                    @"endCursor": [NSNull null]
                }]
            }];
            dict[@"projectNextItems"] = stub;
            HBLogDebug(@"[GitHubLegacyFix] Injected stub projectNextItems for __typename=%@", typeName);
            modified = YES;
        }
        // projectsNext — list of Projects Next on User/Organization/Repository, removed from schema.
        static NSSet<NSString *> *sProjectsNextTypes = nil;
        if (!sProjectsNextTypes)
            sProjectsNextTypes = [NSSet setWithObjects:@"User", @"Organization", @"Repository", nil];
        if ([sProjectsNextTypes containsObject:typeName] && !dict[@"projectsNext"]) {
            NSMutableDictionary *stub = [NSMutableDictionary dictionaryWithDictionary:@{
                @"__typename": @"ProjectNextConnection",
                @"nodes": [NSMutableArray array],
                @"totalCount": @0,
                @"pageInfo": [NSMutableDictionary dictionaryWithDictionary:@{
                    @"__typename": @"PageInfo",
                    @"hasNextPage": @NO,
                    @"hasPreviousPage": @NO,
                    @"startCursor": [NSNull null],
                    @"endCursor": [NSNull null]
                }]
            }];
            dict[@"projectsNext"] = stub;
            HBLogDebug(@"[GitHubLegacyFix] Injected stub projectsNext for __typename=%@", typeName);
            modified = YES;
        }
        for (id value in dict.allValues) {
            if (injectRemovedFieldStubs(value)) modified = YES;
        }
        return modified;
    } else if ([node isKindOfClass:[NSMutableArray class]]) {
        BOOL modified = NO;
        for (id item in (NSMutableArray *)node) {
            if (injectRemovedFieldStubs(item)) modified = YES;
        }
        return modified;
    }
    return NO;
}

static NSData *patchedGraphQLResponse(NSData *responseData, NSString *variantTag) {
    if (responseData.length == 0) return responseData;

    NSError *err = nil;
    id json = [NSJSONSerialization JSONObjectWithData:responseData
                                             options:NSJSONReadingMutableContainers
                                               error:&err];
    if (err || ![json isKindOfClass:[NSMutableDictionary class]]) return responseData;

    NSMutableDictionary *dict = (NSMutableDictionary *)json;
    NSArray *errors = dict[@"errors"];
    id data = dict[@"data"];

#if DEBUG
    // Log the full response body so we can see what the server returns.
    NSString *responseStr = [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding];
    HBLogDebug(@"[GitHubLegacyFix] [%@] Response (%.2000s)", variantTag, responseStr.UTF8String);
#endif

    if (!data || data == [NSNull null]) return responseData;

    BOOL needsReserialise = NO;

    if (errors.count > 0) {
        static NSSet<NSString *> *sRealErrorTypes = nil;
        if (!sRealErrorTypes) {
            sRealErrorTypes = [NSSet setWithObjects:
                @"NOT_FOUND", @"FORBIDDEN", @"UNAUTHORIZED", @"INTERNAL",
                @"MAX_NODE_LIMIT_EXCEEDED", @"RATE_LIMITED", @"SERVICE_UNAVAILABLE",
                @"INSUFFICIENT_SCOPES", @"MISSING_REQUIRED_PARAMETERS", nil];
        }
        for (NSDictionary *e in errors) {
            NSString *etype = e[@"type"];
            if (etype && [sRealErrorTypes containsObject:etype]) {
                return responseData;
            }
        }

        [dict removeObjectForKey:@"errors"];
        HBLogDebug(@"[GitHubLegacyFix] [%@] Stripped %lu deprecated-field error(s)", variantTag, (unsigned long)errors.count);
        needsReserialise = YES;
    }

    if (injectRemovedFieldStubs(data)) {
        needsReserialise = YES;
    }

    if (!needsReserialise) return responseData;

    NSData *cleaned = [NSJSONSerialization dataWithJSONObject:dict options:0 error:&err];
    if (!err && cleaned) {
        HBLogDebug(@"[GitHubLegacyFix] [%@] Patched response %lu → %lu bytes",
              variantTag, (unsigned long)responseData.length, (unsigned long)cleaned.length);
        return cleaned;
    }
    HBLogDebug(@"[GitHubLegacyFix] [%@] Re-serialisation failed: %@", variantTag, err);
    return responseData;
}

static const char kAccumulatedDataKey = 0;
static const char kInjectingKey = 0;

%hook _TtC6Apollo16URLSessionClient

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {

    NSURLRequest *req = dataTask.originalRequest ?: dataTask.currentRequest;
    if (isGitHubGraphQLRequest(req) &&
        !objc_getAssociatedObject(dataTask, &kInjectingKey)) {
        NSMutableData *acc = objc_getAssociatedObject(dataTask, &kAccumulatedDataKey);
        if (!acc) {
            acc = [NSMutableData data];
            objc_setAssociatedObject(dataTask, &kAccumulatedDataKey, acc,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [acc appendData:data];
        %orig(session, dataTask, [NSData data]);
        return;
    }
    %orig;
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {

    NSURLRequest *req = task.originalRequest ?: task.currentRequest;
    if (!error && isGitHubGraphQLRequest(req) && [task isKindOfClass:[NSURLSessionDataTask class]]) {
        NSMutableData *acc = objc_getAssociatedObject(task, &kAccumulatedDataKey);
        if (acc && acc.length > 0) {
            NSData *patched = patchedGraphQLResponse(acc, @"V2/apolloDelegate");
            objc_setAssociatedObject(task, &kInjectingKey, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            typedef void (*didReceiveDataIMP)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *);
            ((didReceiveDataIMP)objc_msgSend)(self,
                @selector(URLSession:dataTask:didReceiveData:),
                session,
                (NSURLSessionDataTask *)task,
                patched);
            objc_setAssociatedObject(task, &kInjectingKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(task, &kAccumulatedDataKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    %orig;
}

%end

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {

    if (isGitHubGraphQLRequest(request)) {
        NSMutableURLRequest *reqToSend = nil;
        if (request.HTTPBody.length > 0) {
            NSData *patched = patchedBodyForGraphQLRequest(request.HTTPBody);
            if (patched != request.HTTPBody) {
                reqToSend = [request mutableCopy];
                reqToSend.HTTPBody = patched;
                [reqToSend setValue:[@(patched.length) stringValue] forHTTPHeaderField:@"Content-Length"];
            }
        }

        void (^wrappedCompletion)(NSData *, NSURLResponse *, NSError *) =
            ^(NSData *data, NSURLResponse *resp, NSError *error) {
                completionHandler(data && !error ? patchedGraphQLResponse(data, @"V1") : data, resp, error);
            };
        return %orig(reqToSend ?: request, wrappedCompletion);
    }

    return %orig;
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {

    if (isGitHubGraphQLRequest(request)) {
        if (request.HTTPBody.length > 0) {
            NSData *patched = patchedBodyForGraphQLRequest(request.HTTPBody);
            if (patched != request.HTTPBody) {
                NSMutableURLRequest *m = [request mutableCopy];
                m.HTTPBody = patched;
                [m setValue:[@(patched.length) stringValue] forHTTPHeaderField:@"Content-Length"];
                return %orig(m);
            }
        }
    }

    return %orig;
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request
                                         fromData:(NSData *)bodyData
                               completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {

    if (isGitHubGraphQLRequest(request)) {
        NSData *dataToSend = bodyData;
        NSMutableURLRequest *reqToSend = [request mutableCopy];
        NSData *patched = patchedBodyForGraphQLRequest(bodyData);
        if (patched != bodyData) {
            dataToSend = patched;
            [reqToSend setValue:[@(patched.length) stringValue] forHTTPHeaderField:@"Content-Length"];
        }

        void (^wrappedCompletion)(NSData *, NSURLResponse *, NSError *) =
            ^(NSData *data, NSURLResponse *resp, NSError *error) {
                completionHandler(data && !error ? patchedGraphQLResponse(data, @"V3") : data, resp, error);
            };
        return %orig(reqToSend, dataToSend, wrappedCompletion);
    }

    return %orig;
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request
                                         fromData:(NSData *)bodyData {

    if (isGitHubGraphQLRequest(request)) {
        NSData *patched = patchedBodyForGraphQLRequest(bodyData);
        if (patched != bodyData) {
            NSMutableURLRequest *m = [request mutableCopy];
            [m setValue:[@(patched.length) stringValue] forHTTPHeaderField:@"Content-Length"];
            return %orig(m, patched);
        }
    }

    return %orig;
}

%end
