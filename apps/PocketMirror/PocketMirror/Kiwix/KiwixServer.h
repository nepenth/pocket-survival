#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs libkiwix's own HTTP server (the same one as kiwix-serve) inside the app: browse and
/// full-text search every ZIM archive it is given.
@interface KiwixServer : NSObject

/// Opens the archives and starts serving on `port`. Bound to 127.0.0.1 unless `lan` is YES.
/// Returns the number of archives opened (0 means the server didn't start; see `lastError`).
- (NSInteger)startWithZimPaths:(NSArray<NSString *> *)paths port:(int)port lan:(BOOL)lan;
- (void)stop;

@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, readonly, nullable) NSString *lastError;
/// Titles of the archives being served, in the order given.
@property (nonatomic, readonly) NSArray<NSString *> *titles;

@end

NS_ASSUME_NONNULL_END
