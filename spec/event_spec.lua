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
