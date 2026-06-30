local event = require('fundo.lib.event')

describe('event.', function()
    before_each(function()
        event._collection = {}
    end)

    after_each(function()
        event._collection = {}
    end)

    it('continues emitting when one listener fails.', function()
        local called = false
        event:on('TestEvent', function()
            error('listener failed')
        end)
        event:on('TestEvent', function(value)
            called = value
        end)

        event:emit('TestEvent', true)

        assert.True(called)
    end)

    it('logs listener failures while continuing to emit.', function()
        local log = require('fundo.lib.log')
        local errorLog = log.error
        local logged
        local called = false

        log.error = function(...)
            logged = {...}
        end
        event:on('TestEvent', function()
            error('listener failed')
        end)
        event:on('TestEvent', function()
            called = true
        end)

        event:emit('TestEvent')
        log.error = errorLog

        assert.True(called)
        assert.same('event listener failed:', logged[1])
        assert.same('TestEvent', logged[2])
        assert.truthy(tostring(logged[3]):match('listener failed'))
    end)

    it('continues emitting when a listener unregisters itself.', function()
        local disposed
        local called = false

        disposed = event:on('TestEvent', function()
            disposed:dispose()
        end)
        event:on('TestEvent', function()
            called = true
        end)

        event:emit('TestEvent')

        assert.True(called)
    end)
end)
