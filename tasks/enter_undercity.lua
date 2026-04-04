local plugin_label = 'wonder_city'

local gui = require 'gui'
local utils = require "core.utils"
local settings = require 'core.settings'
local tracker = require 'core.tracker'
local path = require 'data.path'

local status_enum = {
    IDLE     = 'idle',
    WALKING  = 'walking to ',
    OPENING  = 'opening undercity',
    ENTERING = 'entering undercity',
    WAITING  = 'waiting ',
}

local CLICK_DELAY = 2.0  -- seconds to wait after every click action

-- Steps shared by both flows. Bargain flow inserts extra steps between TRIBUTE_WAIT and OPEN_PORTAL.
local STEP = {
    TRIBUTE             = 1,
    TRIBUTE_WAIT        = 2,
    BARGAIN_OPEN        = 3,   -- bargain flow only: click bargain opener
    BARGAIN_OPEN_WAIT   = 4,
    BARGAIN_SCROLL      = 5,   -- bargain flow only: click scroll bar (if needed)
    BARGAIN_SCROLL_WAIT = 6,
    BARGAIN_SELECT      = 7,   -- bargain flow only: click bargain option
    BARGAIN_SELECT_WAIT = 8,
    OPEN_PORTAL         = 9,
    OPEN_PORTAL_WAIT    = 10,
    ACCEPT              = 11,
    ACCEPT_WAIT         = 12,  -- waiting for portal actor to appear; timeout retries next bargain
}

local INVENTORY_COLS = 4

local task = {
    name             = 'enter_undercity',
    status           = status_enum['IDLE'],
    interacted       = false,
    debounce_time    = -1,
    step             = 0,
    step_time        = -1,
    bargain_idx      = 0,    -- current index into sorted bargain list
    bargain_walk_away = false,
}

local get_sorted_bargains = function ()
    local result = {}
    for i, bargain in ipairs(gui.bargains_data) do
        local p = settings.bargain_priorities[i]
        if p and p > 0 then
            result[#result + 1] = {priority = p, bargain = bargain}
        end
    end
    table.sort(result, function(a, b) return a.priority < b.priority end)
    return result
end

local reset_state = function ()
    task.step      = 0
    task.step_time = -1
    task.bargain_idx = 0
end

local slot_screen_pos = function (slot_index)
    local col = slot_index % INVENTORY_COLS
    local row = math.floor(slot_index / INVENTORY_COLS)
    return settings.inventory_slot_0_x + col * settings.inventory_cell_size,
           settings.inventory_slot_0_y + row * settings.inventory_cell_size
end

local pick_tribute = function ()
    local lp = get_local_player()
    if not lp then return end
    local key_items = lp:get_dungeon_key_items()
    if not key_items or #key_items == 0 then return end
    local best_item, best_priority = nil, math.huge
    for _, item in ipairs(key_items) do
        local p = settings.tribute_priorities[item:get_sno_id()]
        if p and p > 0 and p < best_priority then
            best_item = item
            best_priority = p
        end
    end
    return best_item or key_items[1], lp
end

-- ── Step machine ─────────────────────────────────────────────────────────────
local run_steps = function ()
    local now = get_time_since_inject()

    -- Initialise on first call after interact
    if task.step == 0 then
        task.step = STEP.TRIBUTE
    end

    -- Helper: waiting for delay after a click
    local function waiting(label)
        if now < task.step_time + CLICK_DELAY then
            task.status = status_enum['WAITING'] .. label
            return true
        end
        return false
    end

    -- ── Shared: tribute ───────────────────────────────────────────────────
    if task.step == STEP.TRIBUTE then
        local item, lp = pick_tribute()
        if item and lp then
            local slot = lp:get_item_slot_index(item, 4)
            local sx, sy = slot_screen_pos(slot)
            utility.send_mouse_right_click(sx, sy)
            task.step = STEP.TRIBUTE_WAIT
            task.step_time = now
            task.status = status_enum['WAITING'] .. 'tribute'
        end
        return
    end

    if task.step == STEP.TRIBUTE_WAIT then
        if waiting('tribute') then return end
        if settings.enable_bargains then
            task.step = STEP.BARGAIN_OPEN
        else
            task.step = STEP.OPEN_PORTAL
        end
        return
    end

    -- ── Bargain only ──────────────────────────────────────────────────────
    if task.step == STEP.BARGAIN_OPEN then
        local sorted = get_sorted_bargains()
        task.bargain_idx = task.bargain_idx + 1
        if task.bargain_idx > #sorted then
            task.step = STEP.OPEN_PORTAL
        else
            local cp = settings.bargain_cp['bargain_opener']
            utility.send_mouse_click(cp.x, cp.y)
            task.step = STEP.BARGAIN_OPEN_WAIT
            task.step_time = now
            task.status = status_enum['WAITING'] .. 'bargain menu'
        end
        return
    end

    if task.step == STEP.BARGAIN_OPEN_WAIT then
        if waiting('bargain menu') then return end
        local sorted = get_sorted_bargains()
        local current = sorted[task.bargain_idx]
        if current and current.bargain.needs_scroll then
            task.step = STEP.BARGAIN_SCROLL
        else
            task.step = STEP.BARGAIN_SELECT
        end
        return
    end

    if task.step == STEP.BARGAIN_SCROLL then
        local cp = settings.bargain_cp['scroll_bar']
        utility.send_mouse_click(cp.x, cp.y)
        task.step = STEP.BARGAIN_SCROLL_WAIT
        task.step_time = now
        task.status = status_enum['WAITING'] .. 'scroll'
        return
    end

    if task.step == STEP.BARGAIN_SCROLL_WAIT then
        if waiting('scroll') then return end
        task.step = STEP.BARGAIN_SELECT
        return
    end

    if task.step == STEP.BARGAIN_SELECT then
        local sorted = get_sorted_bargains()
        local current = sorted[task.bargain_idx]
        if current then
            local cp = settings.bargain_cp[current.bargain.cp_key]
            utility.send_mouse_click(cp.x, cp.y)
            task.status = 'selecting: ' .. current.bargain.name
        end
        task.step = STEP.BARGAIN_SELECT_WAIT
        task.step_time = now
        return
    end

    if task.step == STEP.BARGAIN_SELECT_WAIT then
        if waiting('bargain select') then return end
        task.step = STEP.OPEN_PORTAL
        return
    end

    -- ── Shared: open portal ───────────────────────────────────────────────
    if task.step == STEP.OPEN_PORTAL then
        utility.send_mouse_click(settings.portal_button_x, settings.portal_button_y)
        task.step = STEP.OPEN_PORTAL_WAIT
        task.step_time = now
        task.status = status_enum['WAITING'] .. 'open portal'
        return
    end

    if task.step == STEP.OPEN_PORTAL_WAIT then
        if waiting('open portal') then return end
        task.step = STEP.ACCEPT
        return
    end

    -- ── Shared: accept ────────────────────────────────────────────────────
    if task.step == STEP.ACCEPT then
        utility.send_mouse_click(settings.accept_button_x, settings.accept_button_y)
        task.step = STEP.ACCEPT_WAIT
        task.step_time = now
        task.status = status_enum['WAITING'] .. 'accept'
        return
    end

    if task.step == STEP.ACCEPT_WAIT then
        if waiting('accept') then return end
        if now > task.step_time + CLICK_DELAY + settings.bargain_timeout then
            if settings.enable_bargains then
                task.bargain_walk_away = true
                task.step = STEP.BARGAIN_OPEN
                task.step_time = -1
                task.status = 'bargain failed - walking away'
            else
                task.step = STEP.ACCEPT
            end
        else
            task.status = status_enum['WAITING'] .. 'for portal'
        end
        return
    end
end

-- ── Common obelisk wrapper ────────────────────────────────────────────────────
local open_portal = function (delay)
    task.status = status_enum['OPENING']
    local spirit_brazier = utils.get_spirit_brazier()
    if spirit_brazier == nil or spirit_brazier.get_position == nil then return end

    if not loot_manager:is_in_vendor_screen() and not task.interacted then
        interact_object(spirit_brazier)
    elseif not task.interacted then
        task.interacted = true
        reset_state()
    end

    if loot_manager:is_in_vendor_screen() then
        run_steps()
    elseif delay and task.debounce_time + settings.confirm_delay > get_time_since_inject() then
        task.status = status_enum['WAITING'] .. 'for confirmation'
        return
    else
        task.interacted = false
    end
    task.debounce_time = get_time_since_inject()
end

local enter_portal = function (portal)
    interact_object(portal)
    BatmobilePlugin.reset(plugin_label)
    tracker.undercity_start_time = get_time_since_inject()
    tracker.exit_trigger_time = nil
    tracker.exit_reset = false
    tracker.boss_trigger_time = nil
    tracker.boss_kill_time = nil
    tracker.enticement = {}
    tracker.done = false
    task.status = status_enum['ENTERING']
end

task.shouldExecute = function ()
    return utils.player_in_zone('Naha_Kurast')
end

task.Execute = function ()
    local local_player = get_local_player()
    if not local_player then return end
    BatmobilePlugin.pause(plugin_label)

    local player_pos = local_player:get_position()
    local spirit_brazier = utils.get_spirit_brazier()
    local portal = utils.get_entrance_portal()

    -- Walk away from obelisk to reset after a failed bargain
    if task.bargain_walk_away then
        if spirit_brazier == nil or utils.distance(player_pos, spirit_brazier) > 10 then
            task.bargain_walk_away = false
            task.interacted = false
        else
            BatmobilePlugin.set_target(plugin_label, path[1])
            BatmobilePlugin.move(plugin_label)
            task.status = 'bargain failed - walking away'
        end
        return
    end

    if portal ~= nil then
        if utils.distance(player_pos, portal) > 2 then
            BatmobilePlugin.set_target(plugin_label, portal)
            BatmobilePlugin.move(plugin_label)
            task.status = status_enum['WALKING'] .. 'portal'
        else
            enter_portal(portal)
        end
    elseif spirit_brazier == nil or utils.distance(player_pos, spirit_brazier) > 2 then
        if spirit_brazier ~= nil then
            BatmobilePlugin.set_target(plugin_label, spirit_brazier)
            BatmobilePlugin.move(plugin_label)
            task.status = status_enum['WALKING'] .. 'spirit brazier'
        end
    elseif not settings.party_enabled then
        BatmobilePlugin.clear_target(plugin_label)
        open_portal(false)
    elseif settings.party_mode == 0 then
        BatmobilePlugin.clear_target(plugin_label)
        open_portal(true)
    else
        BatmobilePlugin.clear_target(plugin_label)
        if task.status ~= status_enum['WAITING'] .. 'for portal' and
            settings.use_magoogle_tool and settings.party_enabled and
            settings.party_mode == 1
        then
            -- contact magoogle tool accepting portal
        end
        task.status = status_enum['WAITING'] .. 'for portal'
    end
end

return task
