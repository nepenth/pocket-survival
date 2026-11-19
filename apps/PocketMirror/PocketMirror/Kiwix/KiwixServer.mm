#import "KiwixServer.h"

#include <memory>
#include <string>
#include <kiwix/book.h>
#include <kiwix/library.h>
#include <kiwix/manager.h>
#include <kiwix/name_mapper.h>
#include <kiwix/server.h>

@implementation KiwixServer {
    std::shared_ptr<kiwix::Library> _library;
    std::shared_ptr<kiwix::NameMapper> _nameMapper;
    std::unique_ptr<kiwix::Server> _server;
    NSArray<NSString *> *_titles;
    NSString *_lastError;
}

- (instancetype)init {
    if ((self = [super init])) { _titles = @[]; }
    return self;
}

- (BOOL)isRunning { return _server != nullptr; }
- (NSString *)lastError { return _lastError; }
- (NSArray<NSString *> *)titles { return _titles; }

- (NSInteger)startWithZimPaths:(NSArray<NSString *> *)paths port:(int)port lan:(BOOL)lan {
    [self stop];
    _lastError = nil;
    try {
        _library = kiwix::Library::create();
        kiwix::Manager manager(_library);
        NSMutableArray<NSString *> *titles = [NSMutableArray array];
        for (NSString *path in paths) {
            std::string p = path.fileSystemRepresentation;
            try {
                std::string id = manager.addBookFromPathAndGetId(p, p, "", false);
                if (id.empty()) continue;
                const kiwix::Book &book = _library->getBookById(id);
                [titles addObject:[NSString stringWithUTF8String:book.getTitle().c_str()] ?: path.lastPathComponent];
            } catch (const std::exception &e) {
                NSLog(@"Kiwix: skipping %@: %s", path.lastPathComponent, e.what());
            }
        }
        _titles = titles;
        if (titles.count == 0) {
            _lastError = @"No readable ZIM archives found.";
            _library.reset();
            return 0;
        }
        _nameMapper = std::make_shared<kiwix::HumanReadableNameMapper>(*_library, false);
        auto server = std::make_unique<kiwix::Server>(_library, _nameMapper);
        server->setAddress(lan ? "" : "127.0.0.1");
        server->setPort(port);
        server->setNbThreads(4);
        server->setTaskbar(true, true);
        server->setBlockExternalLinks(true); // offline: warn before leaving for the internet
        if (!server->start()) {
            _lastError = [NSString stringWithFormat:@"The library server couldn't start on port %d.", port];
            _library.reset();
            return 0;
        }
        _server = std::move(server);
        return (NSInteger)titles.count;
    } catch (const std::exception &e) {
        _lastError = [NSString stringWithUTF8String:e.what()];
        _server.reset();
        _library.reset();
        return 0;
    }
}

- (void)stop {
    if (_server) {
        _server->stop();
        _server.reset();
    }
    _nameMapper.reset();
    _library.reset();
}

- (void)dealloc { [self stop]; }

@end
