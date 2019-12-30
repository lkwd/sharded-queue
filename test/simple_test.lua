local t = require('luatest')
local g = t.group('simple_test')

local config = require('test.helper.config')
local utils = require('test.helper.utils')

g.before_all = function()
    g.queue_conn = config.cluster:server('queue-router').net_box
end

local function shape_cmd(tube_name, cmd)
    return string.format('queue.tube.%s:%s', tube_name, cmd)
end

for test_name, options in pairs({
    fifottl = {},
    fifo = {
        temporary = true,
        driver = 'sharded_queue.drivers.fifo'
    }
}) do
    g['test_put_taken_' .. test_name] = function()
        local tube_name = 'put_taken_test_' .. test_name

        g.queue_conn:call('queue.create_tube', {
            tube_name,
            options
        })

        -- tasks data for putting
        local task_count = 100
        local tasks_data = {}
        for i = 1, task_count do
            table.insert(tasks_data, {
                name = 'task_' .. i,
                raw = '*'
            })
        end
        -- returned tasks
        local task_ids = {}
        for _, data in pairs(tasks_data) do
            local task = g.queue_conn:call(shape_cmd(tube_name, 'put'), { data })

            local peek_task = g.queue_conn:call(shape_cmd(tube_name, 'peek'),
                    {
                        task[utils.index.task_id]
                    })

            t.assert_equals(peek_task[utils.index.status], utils.state.READY)
            table.insert(task_ids, task[utils.index.task_id])
        end
        -- try taken this tasks
        local taken_task_ids = {}
        for _ = 1, #task_ids do
            local task = g.queue_conn:call(shape_cmd(tube_name, 'take'))
            local peek_task = g.queue_conn:call(shape_cmd(tube_name, 'peek'), {
                task[utils.index.task_id]
            })
            t.assert_equals(peek_task[utils.index.status], utils.state.TAKEN)
            table.insert(taken_task_ids, task[utils.index.task_id])
        end
        -- compare
        local stat = g.queue_conn:call('queue.statistics', { tube_name })
        if stat ~= nil then
            t.assert_equals(stat.tasks.ready, 0)
            t.assert_equals(stat.tasks.taken, task_count)

            t.assert_equals(stat.calls.put, task_count)
            t.assert_equals(stat.calls.take, task_count)
        end

        for _, task_id in pairs(task_ids) do
            g.queue_conn:call(shape_cmd(tube_name, 'ack'), {task_id})
        end

        t.assert_equals(utils.equal_sets(task_ids, taken_task_ids), true)
    end
end

function g.test_delete()
    local tube_name = 'delete_test'
    g.queue_conn:call('queue.create_tube', {
        tube_name
    })

    -- task data for putting
    local task_count = 20
    local tasks_data = {}

    for i = 1, task_count do
        table.insert(tasks_data, {
            name = 'task_' .. i,
            raw = '*'
        })
    end

    -- returned tasks
    local task_ids = {}
    for _, data in pairs(tasks_data) do
        local task = g.queue_conn:call(shape_cmd(tube_name, 'put'), { data })
        local peek_task = g.queue_conn:call(shape_cmd(tube_name, 'peek'), {
            task[utils.index.task_id]
        })
        t.assert_equals(peek_task[utils.index.status], utils.state.READY)
        table.insert(task_ids, task[utils.index.task_id])
    end

    -- delete few tasks
    local deleted_tasks_count = 10
    local deleted_tasks = {}

    for i = 1, deleted_tasks_count do
        table.insert(deleted_tasks,
            g.queue_conn:call(shape_cmd(tube_name, 'delete'), { task_ids[i] })[utils.index.task_id])
    end

    -- taken tasks
    local taken_task_ids = {}
    for _ = 1, task_count - deleted_tasks_count do
        local task = g.queue_conn:call(shape_cmd(tube_name, 'take'))
        local peek_task = g.queue_conn:call(shape_cmd(tube_name, 'peek'), {
            task[utils.index.task_id]
        })
        t.assert_equals(peek_task[utils.index.status], utils.state.TAKEN)
        table.insert(taken_task_ids, task[utils.index.task_id])
    end
    --
    local excepted_task_ids = {}
    for i = deleted_tasks_count + 1, #task_ids do
        table.insert(excepted_task_ids, task_ids[i])
    end

    -- compare

    local stat = g.queue_conn:call('queue.statistics', { tube_name })

    t.assert_equals(stat.tasks.ready, 0)
    t.assert_equals(stat.tasks.taken, task_count - deleted_tasks_count)

    t.assert_equals(stat.calls.put, task_count)
    t.assert_equals(stat.calls.delete, deleted_tasks_count)

    t.assert_equals(utils.equal_sets(excepted_task_ids, taken_task_ids), true)
end

function g.test_release()
    local tube_name = 'release_test'
        g.queue_conn:call('queue.create_tube', {
        tube_name
    })

    local task_count = 10
    local tasks_data = {}

    for i = 1, task_count do
        table.insert(tasks_data, {
            name = 'task_' .. i,
            raw = '*'
        })
    end

    -- returned tasks
    local task_ids = {}
    for _, data in pairs(tasks_data) do
        local task = g.queue_conn:call(shape_cmd(tube_name, 'put'), { data })
        t.assert_equals(task[utils.index.status], utils.state.READY)
        table.insert(task_ids, task[utils.index.task_id])
    end

    -- take few tasks
    local taken_task_count = 5
    local taken_task_ids = {}

    for _ = 1, taken_task_count do
        local task = g.queue_conn:call(shape_cmd(tube_name, 'take'))
        t.assert_equals(task[utils.index.status], utils.state.TAKEN)
        table.insert(taken_task_ids, task[utils.index.task_id])
    end

    t.assert_equals(utils.subset_of(taken_task_ids, task_ids), true)

    for _, task_id in pairs(taken_task_ids) do
        local task = g.queue_conn:call(shape_cmd(tube_name, 'release'), { task_id })
        t.assert_equals(task[utils.index.status], utils.state.READY)
    end

    local result_task_id = {}

    for _ = 1, task_count do
        table.insert(result_task_id,
            g.queue_conn:call(shape_cmd(tube_name, 'take'))[utils.index.task_id])
    end

    local stat = g.queue_conn:call('queue.statistics', { tube_name })

    t.assert_equals(stat.tasks.ready, 0)
    t.assert_equals(stat.tasks.taken, task_count)

    t.assert_equals(stat.calls.put, task_count)
    t.assert_equals(stat.calls.release, taken_task_count)
    t.assert_equals(stat.calls.take, task_count + taken_task_count)

    t.assert_equals(utils.equal_sets(task_ids, result_task_id), true)
end

function g.test_bury_kick()
    local tube_name = 'bury_kick_test'
    g.queue_conn:call('queue.create_tube', {
        tube_name
    })

    local cur_stat

    local task_count = 10

    -- returned tasks
    local task_ids = {}
    for i = 1, task_count do
        local task = g.queue_conn:call(shape_cmd(tube_name, 'put'), { i })
        table.insert(task_ids, task[utils.index.task_id])
    end

    -- bury few task
    local bury_task_count = 5
    for i = 1, bury_task_count do
        local task = g.queue_conn:call(shape_cmd(tube_name, 'bury'), { task_ids[i] })
        t.assert_equals(task[utils.index.status], utils.state.BURIED)
    end

    cur_stat = g.queue_conn:call('queue.statistics', { tube_name })
    t.assert_equals(cur_stat.tasks.buried, bury_task_count)
    t.assert_equals(cur_stat.tasks.ready, task_count - bury_task_count)

    -- try unbury few task > bury_task_count
    local kick_cmd = shape_cmd(tube_name, 'kick')
    t.assert_equals(g.queue_conn:call(kick_cmd, {bury_task_count + 3}), bury_task_count)

    cur_stat = g.queue_conn:call('queue.statistics', { tube_name })
    t.assert_equals(cur_stat.calls.kick, bury_task_count)
    t.assert_equals(cur_stat.tasks.ready, task_count)
end
