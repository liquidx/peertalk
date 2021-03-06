#import "PTChannel.h"

#include <sys/ioctl.h>
#include <sys/un.h>
#include <err.h>
#include <fcntl.h>
#include <arpa/inet.h>
#import <objc/runtime.h>

// Read member of sockaddr_in without knowing the family
#define PT_SOCKADDR_ACCESS(ss, member4, member6) \
  (((ss)->ss_family == AF_INET) ? ( \
    ((const struct sockaddr_in *)(ss))->member4 \
  ) : ( \
    ((const struct sockaddr_in6 *)(ss))->member6 \
  ))

// Connection state (storage: uint8_t)
#define kConnStateNone 0
#define kConnStateConnecting 1
#define kConnStateConnected 2
#define kConnStateListening 3

// Delegate support optimization (storage: uint8_t)
#define kDelegateFlagImplements_ioFrameChannel_shouldAcceptFrameOfType_tag_payloadSize 1
#define kDelegateFlagImplements_ioFrameChannel_didEndWithError 2
#define kDelegateFlagImplements_ioFrameChannel_didAcceptConnection_fromAddress 4


#pragma mark -
// Note: We are careful about the size of this struct as each connected peer
// implies one allocation of this struct.
@interface PTChannel ()
@property(strong) dispatch_io_t channel;
@property(strong) dispatch_source_t source;
@property(strong) NSError *endError;

- (id)initWithProtocol:(PTProtocol*)protocol delegate:(id<PTChannelDelegate>)delegate;
- (BOOL)acceptIncomingConnection:(dispatch_fd_t)serverSocketFD;
@end
static const uint8_t kUserInfoKey;

#pragma mark -
@interface PTAddress () {
  struct sockaddr_storage sockaddr_;
}
- (id)initWithSockaddr:(const struct sockaddr_storage*)addr;
@end

#pragma mark -
@implementation PTChannel {
  uint8_t delegateFlags_;
  uint8_t connState_;
}

+ (PTChannel*)channelWithDelegate:(id<PTChannelDelegate>)delegate {
  return [[PTChannel alloc] initWithProtocol:[PTProtocol sharedProtocolForQueue:dispatch_get_main_queue()] delegate:delegate];
}


- (id)initWithProtocol:(PTProtocol*)protocol delegate:(id<PTChannelDelegate>)delegate {
  if (!(self = [super init])) return nil;
  _protocol = protocol;
  [self setDelegate:delegate];
  return self;
}


- (id)initWithProtocol:(PTProtocol*)protocol {
  if (!(self = [super init])) return nil;
  _protocol = protocol;
  return self;
}


- (id)init {
  return [self initWithProtocol:[PTProtocol sharedProtocolForQueue:dispatch_get_main_queue()]];
}


- (BOOL)isConnected {
  return connState_ == kConnStateConnecting || connState_ == kConnStateConnected;
}


- (BOOL)isListening {
  return connState_ == kConnStateListening;
}


- (id)userInfo {
  return objc_getAssociatedObject(self, (void*)&kUserInfoKey);
}

- (void)setUserInfo:(id)userInfo {
  objc_setAssociatedObject(self, (const void*)&kUserInfoKey, userInfo, OBJC_ASSOCIATION_RETAIN);
}


- (void)setConnState:(char)connState {
  connState_ = connState;
}


- (void)setDispatchChannel:(dispatch_io_t)channel {
  assert(connState_ == kConnStateConnecting || connState_ == kConnStateConnected || connState_ == kConnStateNone);
  if (_channel != channel) {
    _channel = channel;
    if (!_channel && !_source) {
      connState_ = kConnStateNone;
    }
  }
}


- (void)setDispatchSource:(dispatch_source_t)source {
  assert(connState_ == kConnStateListening || connState_ == kConnStateNone);
  if (_source != source) {
    _source = source;
    if (!_channel && !_source) {
      connState_ = kConnStateNone;
    }
  }
}

- (void)setDelegate:(id<PTChannelDelegate>)delegate {
  _delegate = delegate;
  delegateFlags_ = 0;

  if ([_delegate respondsToSelector:@selector(ioFrameChannel:shouldAcceptFrameOfType:tag:payloadSize:)]) {
    delegateFlags_ |= kDelegateFlagImplements_ioFrameChannel_shouldAcceptFrameOfType_tag_payloadSize;
  }
  
  if (_delegate && [delegate respondsToSelector:@selector(ioFrameChannel:didEndWithError:)]) {
    delegateFlags_ |= kDelegateFlagImplements_ioFrameChannel_didEndWithError;
  }
  
  if (_delegate && [delegate respondsToSelector:@selector(ioFrameChannel:didAcceptConnection:fromAddress:)]) {
    delegateFlags_ |= kDelegateFlagImplements_ioFrameChannel_didAcceptConnection_fromAddress;
  }
}

#pragma mark - Connecting


- (void)connectToPort:(int)port overUSBHub:(PTUSBHub*)usbHub deviceID:(NSNumber*)deviceID callback:(void(^)(NSError *error))callback {
  assert(_protocol != NULL);
  if (connState_ != kConnStateNone) {
    if (callback) callback([NSError errorWithDomain:NSPOSIXErrorDomain code:EPERM userInfo:nil]);
    return;
  }
  connState_ = kConnStateConnecting;
  [usbHub connectToDevice:deviceID
                     port:port
                  onStart:^(NSError *err, dispatch_io_t dispatchChannel) {
    NSError *error = err;
    if (!error) {
      [self startReadingFromConnectedChannel:dispatchChannel error:&error];
    } else {
      connState_ = kConnStateNone;
    }
    if (callback) callback(error);
  } onEnd:^(NSError *error) {
    if (delegateFlags_ & kDelegateFlagImplements_ioFrameChannel_didEndWithError) {
      [_delegate ioFrameChannel:self didEndWithError:error];
    }
    _endError = nil;
  }];
}


- (void)connectToPort:(in_port_t)port IPv4Address:(in_addr_t)ipv4Address callback:(void(^)(NSError *error, PTAddress *address))callback {
  assert(_protocol != NULL);
  if (connState_ != kConnStateNone) {
    if (callback) callback([NSError errorWithDomain:NSPOSIXErrorDomain code:EPERM userInfo:nil], nil);
    return;
  }
  connState_ = kConnStateConnecting;
  
  int error = 0;
  
  // Create socket
  dispatch_fd_t fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd == -1) {
    perror("socket(AF_INET, SOCK_STREAM, 0) failed");
    error = errno;
    if (callback) callback([[NSError alloc] initWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil], nil);
    return;
  }
  
  // Connect socket
  struct sockaddr_in addr;
  bzero((char *)&addr, sizeof(addr));
  
  addr.sin_len = sizeof(addr);
  addr.sin_family = AF_INET;
  addr.sin_port = htons(port);
  //addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  //addr.sin_addr.s_addr = htonl(INADDR_ANY);
  addr.sin_addr.s_addr = htonl(ipv4Address);
  
  // prevent SIGPIPE
	int on = 1;
	setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
  
  // int socket, const struct sockaddr *address, socklen_t address_len
  if (connect(fd, (const struct sockaddr *)&addr, addr.sin_len) == -1) {
    //perror("connect");
    error = errno;
    close(fd);
    if (callback) callback([[NSError alloc] initWithDomain:NSPOSIXErrorDomain code:error userInfo:nil], nil);
    return;
  }
  
  // get actual address
  //if (getsockname(fd, (struct sockaddr*)&addr, (socklen_t*)&addr.sin_len) == -1) {
  //  error = errno;
  //  close(fd);
  //  if (callback) callback([[NSError alloc] initWithDomain:NSPOSIXErrorDomain code:error userInfo:nil], nil);
  //  return;
  //}
  
  dispatch_io_t dispatchChannel = dispatch_io_create(DISPATCH_IO_STREAM, fd, _protocol.queue, ^(int error) {
    close(fd);
    if (delegateFlags_ & kDelegateFlagImplements_ioFrameChannel_didEndWithError) {
      NSError *err = error == 0 ? _endError : [[NSError alloc] initWithDomain:NSPOSIXErrorDomain code:error userInfo:nil];
      [_delegate ioFrameChannel:self didEndWithError:err];
      _endError = nil;
    }
  });
  
  if (!dispatchChannel) {
    close(fd);
    if (callback) callback([[NSError alloc] initWithDomain:@"PTError" code:0 userInfo:nil], nil);
    return;
  }
  
  // Success
  NSError *err = nil;
  PTAddress *address = [[PTAddress alloc] initWithSockaddr:(struct sockaddr_storage*)&addr];
  [self startReadingFromConnectedChannel:dispatchChannel error:&err];
  if (callback) callback(err, address);
}


#pragma mark - Listening and serving


- (void)listenOnPort:(in_port_t)port IPv4Address:(in_addr_t)address callback:(void(^)(NSError *error))callback {
  if (connState_ != kConnStateNone) {
    if (callback) callback([NSError errorWithDomain:NSPOSIXErrorDomain code:EPERM userInfo:nil]);
    return;
  }
  
  assert(_source == nil);
  
  // Create socket
  dispatch_fd_t fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd == -1) {
    if (callback) callback([NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
    return;
  }
  
  // Connect socket
  struct sockaddr_in addr;
  bzero((char *)&addr, sizeof(addr));
  
  addr.sin_family = AF_INET;
  addr.sin_port = htons(port);
  //addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  //addr.sin_addr.s_addr = htonl(INADDR_ANY);
  addr.sin_addr.s_addr = htonl(address);
  
  socklen_t socklen = sizeof(addr);
  
  int on = 1;
  
  if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on)) == -1) {
    close(fd);
    if (callback) callback([NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
    return;
  }
  
  if (fcntl(fd, F_SETFL, O_NONBLOCK) == -1) {
    close(fd);
    if (callback) callback([NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
    return;
  }
  
  if (bind(fd, (struct sockaddr*)&addr, socklen) != 0) {
    close(fd);
    if (callback) callback([NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
    return;
  }
  
  if (listen(fd, 512) != 0) {
    close(fd);
    if (callback) callback([NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
    return;
  }
  
  [self setDispatchSource:dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, _protocol.queue)];
  
  dispatch_source_set_event_handler(_source, ^{
    unsigned long nconns = dispatch_source_get_data(_source);
    while ([self acceptIncomingConnection:fd] && --nconns);
  });
  
  dispatch_source_set_cancel_handler(_source, ^{
    // Captures *self*, effectively holding a reference to *self* until cancelled.
    _source = nil;
    close(fd);
    if (delegateFlags_ & kDelegateFlagImplements_ioFrameChannel_didEndWithError) {
      [_delegate ioFrameChannel:self didEndWithError:_endError];
      _endError = nil;
    }
  });
  
  dispatch_resume(_source);
  //NSLog(@"%@ opened on fd #%d", self, fd);
  
  connState_ = kConnStateListening;
  if (callback) callback(nil);
}


- (BOOL)acceptIncomingConnection:(dispatch_fd_t)serverSocketFD {
  struct sockaddr_in addr;
  socklen_t addrLen = sizeof(addr);
  dispatch_fd_t clientSocketFD = accept(serverSocketFD, (struct sockaddr*)&addr, &addrLen);
  
  if (clientSocketFD == -1) {
    perror("accept()");
    return NO;
  }
  
  // prevent SIGPIPE
	int on = 1;
	setsockopt(clientSocketFD, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
  
  if (fcntl(clientSocketFD, F_SETFL, O_NONBLOCK) == -1) {
    perror("fcntl(.. O_NONBLOCK)");
    close(clientSocketFD);
    return NO;
  }
  
  if (delegateFlags_ & kDelegateFlagImplements_ioFrameChannel_didAcceptConnection_fromAddress) {
    PTChannel *channel = [[PTChannel alloc] initWithProtocol:_protocol delegate:_delegate];
    dispatch_io_t dispatchChannel = dispatch_io_create(DISPATCH_IO_STREAM, clientSocketFD, _protocol.queue, ^(int error) {
      // Important note: This block captures *self*, thus a reference is held to
      // *self* until the fd is truly closed.
      close(clientSocketFD);
      
      if (channel->delegateFlags_ & kDelegateFlagImplements_ioFrameChannel_didEndWithError) {
        NSError *err = error == 0 ? _endError : [[NSError alloc] initWithDomain:NSPOSIXErrorDomain code:error userInfo:nil];
        [channel->_delegate ioFrameChannel:channel didEndWithError:err];
        _endError = nil;
      }
    });
    
    [channel setConnState:kConnStateConnected];
    [channel setDispatchChannel:dispatchChannel];
    
    assert(((struct sockaddr_storage*)&addr)->ss_len == addrLen);
    PTAddress *address = [[PTAddress alloc] initWithSockaddr:(struct sockaddr_storage*)&addr];
    [_delegate ioFrameChannel:self didAcceptConnection:channel fromAddress:address];
    
    NSError *err = nil;
    if (![channel startReadingFromConnectedChannel:dispatchChannel error:&err]) {
      NSLog(@"startReadingFromConnectedChannel failed in accept: %@", err);
    }
  } else {
    close(clientSocketFD);
  }
  return YES;
}


#pragma mark - Closing the channel


- (void)close {
  if ((connState_ == kConnStateConnecting || connState_ == kConnStateConnected) && _channel) {
    dispatch_io_close(_channel, DISPATCH_IO_STOP);
    [self setDispatchChannel:NULL];
  } else if (connState_ == kConnStateListening && _source) {
    dispatch_source_cancel(_source);
  }
}


- (void)cancel {
  if ((connState_ == kConnStateConnecting || connState_ == kConnStateConnected) && _channel) {
    dispatch_io_close(_channel, 0);
    [self setDispatchChannel:NULL];
  } else if (connState_ == kConnStateListening && _source) {
    dispatch_source_cancel(_source);
  }
}


#pragma mark - Reading


- (BOOL)startReadingFromConnectedChannel:(dispatch_io_t)channel error:(__autoreleasing NSError**)error {
  if (connState_ != kConnStateNone && connState_ != kConnStateConnecting && connState_ != kConnStateConnected) {
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EPERM userInfo:nil];
    return NO;
  }
  
  if (_channel != channel) {
    [self close];
    [self setDispatchChannel:channel];
  }
  
  connState_ = kConnStateConnected;
  
  // helper
  BOOL(^handleError)(NSError*,BOOL) = ^BOOL(NSError *error, BOOL isEOS) {
    if (error) {
      //NSLog(@"Error while communicating: %@", error);
      _endError = error;
      [self close];
      return YES;
    } else if (isEOS) {
      [self cancel];
      return YES;
    }
    return NO;
  };
  
  [_protocol readFramesOverChannel:channel onFrame:^(NSError *error, uint32_t type, uint32_t tag, uint32_t payloadSize, dispatch_block_t resumeReadingFrames) {
    if (handleError(error, type == PTFrameTypeEndOfStream)) {
      return;
    }
    
    BOOL accepted = (channel == _channel);
    if (accepted && (delegateFlags_ & kDelegateFlagImplements_ioFrameChannel_shouldAcceptFrameOfType_tag_payloadSize)) {
      accepted = [_delegate ioFrameChannel:self shouldAcceptFrameOfType:type tag:tag payloadSize:payloadSize];
    }
    
    if (payloadSize == 0) {
      if (accepted && _delegate) {
        [_delegate ioFrameChannel:self didReceiveFrameOfType:type tag:tag payload:nil];
      } else {
        // simply ignore the frame
      }
      resumeReadingFrames();
    } else {
      // has payload
      if (!accepted) {
        // Read and discard payload, ignoring frame
        [_protocol readAndDiscardDataOfSize:payloadSize overChannel:channel callback:^(NSError *error, BOOL endOfStream) {
          if (!handleError(error, endOfStream)) {
            resumeReadingFrames();
          }
        }];
      } else {
        [_protocol readPayloadOfSize:payloadSize
                         overChannel:channel
                            callback:^(NSError *error,
                                       dispatch_data_t contiguousData) {
                              if (handleError(error, dispatch_data_get_size(contiguousData) == 0)) {
                                return;
                              }
          
                              if (_delegate) {
                                
                                [_delegate ioFrameChannel:self didReceiveFrameOfType:type tag:tag payload:contiguousData];
                              }
                              resumeReadingFrames();
                            }];
      }
    }
  }];
  
  return YES;
}


#pragma mark - Sending

- (void)sendFrameOfType:(uint32_t)frameType tag:(uint32_t)tag withPayload:(dispatch_data_t)payload callback:(void(^)(NSError *error))callback {
  if (connState_ == kConnStateConnecting || connState_ == kConnStateConnected) {
    [_protocol sendFrameOfType:frameType tag:tag withPayload:payload overChannel:_channel callback:callback];
  } else if (callback) {
    callback([NSError errorWithDomain:NSPOSIXErrorDomain code:EPERM userInfo:nil]);
  }
}

#pragma mark - NSObject

- (NSString*)description {
  id userInfo = objc_getAssociatedObject(self, (void*)&kUserInfoKey);
  return [NSString stringWithFormat:@"<PTChannel: %p (%@)%s%@>", self, (  connState_ == kConnStateConnecting ? @"connecting"
                                                                    : connState_ == kConnStateConnected  ? @"connected" 
                                                                    : connState_ == kConnStateListening  ? @"listening"
                                                                    :                                      @"closed"),
          userInfo ? " " : "", userInfo ? userInfo : @""];
}


@end


#pragma mark -
@implementation PTAddress

- (id)initWithSockaddr:(const struct sockaddr_storage*)addr {
  if (!(self = [super init])) return nil;
  assert(addr);
  memcpy((void*)&sockaddr_, (const void*)addr, addr->ss_len);  
  return self;
}


- (NSString*)name {
  if (sockaddr_.ss_len) {
    const void *sin_addr = NULL;
    size_t bufsize = 0;
    if (sockaddr_.ss_family == AF_INET6) {
      bufsize = INET6_ADDRSTRLEN;
      sin_addr = (const void *)&((const struct sockaddr_in6*)&sockaddr_)->sin6_addr;
    } else {
      bufsize = INET_ADDRSTRLEN;
      sin_addr = (const void *)&((const struct sockaddr_in*)&sockaddr_)->sin_addr;
    }
    char *buf = CFAllocatorAllocate(kCFAllocatorDefault, bufsize+1, 0);
    if (inet_ntop(sockaddr_.ss_family, sin_addr, buf, (socklen_t)bufsize-1) == NULL) {
      CFAllocatorDeallocate(kCFAllocatorDefault, buf);
      return nil;
    }
    return [[NSString alloc] initWithBytesNoCopy:(void*)buf length:strlen(buf) encoding:NSUTF8StringEncoding freeWhenDone:YES];
  } else {
    return nil;
  }
}


- (NSInteger)port {
  if (sockaddr_.ss_len) {
    return ntohs(PT_SOCKADDR_ACCESS(&sockaddr_, sin_port, sin6_port));
  } else {
    return 0;
  }
}


- (NSString*)description {
  if (sockaddr_.ss_len) {
    return [NSString stringWithFormat:@"%@:%ld", self.name, (long)self.port];
  } else {
    return @"(?)";
  }
}

@end
