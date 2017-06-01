local ffi = require('ffi')
local internal = require('socket')
local buffer = require('buffer')
local fiber = require('fiber')
local fio = require('fio')
local boxerrno = require('errno')

-- check openssl 1.1 exists

local TIMEOUT_INFINITY      = 500 * 365 * 86400
local LIMIT_INFINITY = 2147483647
local SSL_FILETYPE_PEM = 1

ffi.cdef[[
    typedef struct {} SSL_CTX;
    typedef struct {} SSL;
    typedef struct {} SSL_METHOD;
    typedef struct {} OPENSSL_INIT_SETTINGS;
    
    const char *SSLeay_version(int type);

    SSL_METHOD* TLS_server_method ();
    int OPENSSL_init_ssl(uint64_t opts, const OPENSSL_INIT_SETTINGS * settings);

    SSL_CTX *SSL_CTX_new (const SSL_METHOD *method);

    int SSL_CTX_use_certificate_file(SSL_CTX *ctx, const char *file, int type);
    int SSL_CTX_use_PrivateKey_file(SSL_CTX *ctx, const char *file, int type);
    int SSL_CTX_check_private_key(const SSL_CTX *ctx);

    SSL* SSL_new (SSL_CTX* ctx);
    void SSL_set_fd (SSL* ssl, int client);
    void SSL_accept (SSL* ssl);
    int SSL_read (SSL* ssl, void *buf, int num);
    int SSL_write (SSL* ssl, const void *buf, int num);
    void SSL_free (SSL* ssl);
    void SSL_CTX_free (SSL_CTX* ctx);
]]

local errno_is_transient = {
    [boxerrno.EAGAIN] = true;
    [boxerrno.EWOULDBLOCK] = true;
    [boxerrno.EINTR] = true;
}

local errno_is_fatal = {
    [boxerrno.EBADF] = true;
    [boxerrno.EINVAL] = true;
    [boxerrno.EOPNOTSUPP] = true;
    [boxerrno.ENOTSOCK] = true;
}

local lib = ffi.load ("ssl")
-- Init openssl
local function ssl_init ()    
    lib.OPENSSL_init_ssl (0, nil)
end

ssl_init ()

-- Ssl socket methods
local ssl_socket_methods = {}

-- Read method
ssl_socket_methods.read = function (self, opts, timeout)
    return self.sock:read (opts, timeout)
end

-- Write method
ssl_socket_methods.write = function (self, octets, timeout)
    return self.sock:write (octets, timeout)
end

-- Meta table for ssl socket
local ssl_socket_mt = {
    __index     = ssl_socket_methods
}

local function create_ctx ()
    local method = lib.TLS_server_method();
    if (method == nil) then
        error ("Can't get ssl method");
    end

    local ctx = lib.SSL_CTX_new (method);
    if (ctx == nil) then
        error ("Can't create context");
    end
    
    return ctx;
end

-- load certificate
local function load_certificate (ctx, cert, key)
    local cert = ffi.cast('const char *', cert)
    local key = ffi.cast('const char *', key)

    if (lib.SSL_CTX_use_certificate_file(ctx, cert, SSL_FILETYPE_PEM) <= 0) then
        error ("Can't load certificate")
    end
    if (lib.SSL_CTX_use_PrivateKey_file(ctx, key, SSL_FILETYPE_PEM) <= 0) then
        error ("Can't load private key")
    end
    if (not lib.SSL_CTX_check_private_key(ctx)) then
        error ("Wrong private key")
    end
end

local function tcp_server_usage ()
    error ('Usage: socket.tcp_server(host, port, cert, key)')
end

-- check usage parameters for tcp_server
local function check_usage (host, port, cert, key)
    if ((host == nil) or (port == nil) or (cert == nil) or (key == nil)) then
        tcp_server_usage ()
    end
end

local function check_limit(self, limit)
    if self.rbuf:size() >= limit then
        return limit
    end
    return nil
end

local function check_delimiter(self, limit, eols)
    if limit == 0 then
        return 0
    end
    local rbuf = self.rbuf
    if rbuf:size() == 0 then
        return nil
    end

    local shortest
    for i, eol in ipairs(eols) do
        local data = ffi.C.memmem(rbuf.rpos, rbuf:size(), eol, #eol)
        if data ~= nil then
            local len = ffi.cast('char *', data) - rbuf.rpos + #eol
            if shortest == nil or shortest > len then
                shortest = len
            end
        end
    end
    if shortest ~= nil and shortest <= limit then
        return shortest
    elseif limit <= rbuf:size() then
        return limit
    end
    return nil
end

local function sysread(self, charptr, size)
    self._errno = nil
    local ssl = self.parent.ssl
    local res = lib.SSL_read(ssl, charptr, size)    
    if res < 0 then
        self._errno = boxerrno()
        return nil
    end

    return tonumber(res)
end

local function ssl_read (self, limit, timeout, check, ...)
    assert(limit >= 0)
    limit = math.min(limit, LIMIT_INFINITY)
    local rbuf = self.rbuf
    if rbuf == nil then
        rbuf = buffer.ibuf()
        self.rbuf = rbuf
    end

    local len = check(self, limit, ...)
    if len ~= nil then
        self._errno = nil
        local data = ffi.string(rbuf.rpos, len)
        rbuf.rpos = rbuf.rpos + len
        return data
    end

    local started = fiber.time()
    while timeout > 0 do
        local started = fiber.time()

        assert(rbuf:size() < limit)
        local to_read = math.min(limit - rbuf:size(), buffer.READAHEAD)
        local data = rbuf:reserve(to_read)
        assert(rbuf:unused() >= to_read)
        local res = sysread(self, data, rbuf:unused())
        if res == 0 then -- eof
            self._errno = nil
            local len = rbuf:size()
            local data = ffi.string(rbuf.rpos, len)
            rbuf.rpos = rbuf.rpos + len
            return data
        elseif res ~= nil then
            rbuf.wpos = rbuf.wpos + res
            local len = check(self, limit, ...)
            if len ~= nil then
                self._errno = nil
                local data = ffi.string(rbuf.rpos, len)
                rbuf.rpos = rbuf.rpos + len
                return data
            end
        elseif not errno_is_transient[self:errno()] then
            self._errno = boxerrno()
            return nil
        end

        if not self:readable(timeout) then
            return nil
        end
        if timeout <= 0 then
            break
        end
        timeout = timeout - ( fiber.time() - started )
    end
    self._errno = boxerrno.ETIMEDOUT
    return nil
end

local function read (self, opts, timeout)
    timeout = timeout or TIMEOUT_INFINITY
    if type(opts) == 'number' then
        return ssl_read(self, opts, timeout, check_limit)
    elseif type(opts) == 'string' then
        return ssl_read(self, LIMIT_INFINITY, timeout, check_delimiter, { opts })
    elseif type(opts) == 'table' then
        local chunk = opts.chunk or opts.size or LIMIT_INFINITY
        local delimiter = opts.delimiter or opts.line
        if delimiter == nil then
            return ssl_read(self, chunk, timeout, check_limit)
        elseif type(delimiter) == 'string' then
            return ssl_read(self, chunk, timeout, check_delimiter, { delimiter })
        elseif type(delimiter) == 'table' then
            return ssl_read(self, chunk, timeout, check_delimiter, delimiter)
        end
    end
    error('Usage: s:read(delimiter|chunk|{delimiter = x, chunk = x}, timeout)')
end

local function syswrite(self, charptr, size)
    self._errno = nil
    local ssl = self.parent.ssl
    local done = lib.SSL_write (ssl, charptr, size)    
    if done < 0 then
        self._errno = boxerrno()
        return nil
    end    

    return tonumber(done)
end      

local function write (self, octets, timeout)
    if timeout == nil then
        timeout = TIMEOUT_INFINITY
    end

    local s = ffi.cast('const char *', octets)
    local p = s
    local e = s + #octets
    if p == e then
        return 0
    end

    local started = fiber.time()
    while true do
        local written = syswrite(self, p, e - p)
        if written == 0 then
            return p - s -- eof
        elseif written ~= nil then
            p = p + written
            assert(p <= e)
            if p == e then
                return e - s
            end
        elseif not errno_is_transient[self:errno()] then
            return nil
        end

        timeout = timeout - (fiber.time() - started)
        if timeout <= 0 or not self:writable(timeout) then
            break
        end
    end    
end          

local function create_ssl_client_socket (sock, ssl)
    local ssl_object = {}
    ssl_object.sock = sock
    ssl_object.ssl = ssl
    return setmetatable (ssl_object, ssl_socket_mt)
end

-- on socket accept
local function on_accept (server, client, from)
    local ssl = lib.SSL_new (server.ctx)
    lib.SSL_set_fd (ssl, client:fd ())

    if (lib.SSL_accept(ssl) == -1) then
        error ("Can't ssl accept")
    end        
    
    local sock = create_ssl_client_socket (client, ssl)

    -- override read function
    client.read = read
    -- override write function
    client.write = write
    client.parent = sock

    server.handler (sock, from)
    lib.SSL_free(ssl);
end

local function create_ssl_server_socket (ctx, handler)    
    local ssl_object = {}
    ssl_object.server_socket = nil
    ssl_object.ctx = ctx
    ssl_object.on_accept = function (sock, from)
        on_accept (ssl_object, sock, from)
    end

    ssl_object.handler = handler

    -- For garbage collector. Free context and server socket
    local mt = { __gc = function (ssl_sock)
            lib.SSL_CTX_free (ssl_sock.ctx)
        end
    } 
    local prox = newproxy(true)
    getmetatable(prox).__gc = function ()
       mt.__gc(ssl_object)
    end 
    ssl_object[prox] = true

    return setmetatable (ssl_object, ssl_socket_mt)
end

local function tcp_server (host, port, cert, key, handler, timeout)
    if (timeout == nil) then 
        timeout = 0
    end

    check_usage (host, port, cert, key)

    local ctx = create_ctx ()
    if (ctx == nil) then
        error ("Can't create ssl context")
    end    

    load_certificate (ctx, cert, key)

    local sock = create_ssl_server_socket (ctx, handler)
    internal.tcp_server (host, port, sock.on_accept)
    return sock
end

return setmetatable ({
    tcp_server = tcp_server
}, {})