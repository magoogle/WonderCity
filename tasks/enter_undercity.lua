local plugin_label = 'wonder_city' -- change to your plugin name

local gui = require 'gui'
local utils = require "core.utils"
local settings = require 'core.settings'
local tracker = require 'core.tracker'
local path = require 'data.path'

local status_enum = {
    IDLE = 'idle',
    WALKING = 'walking to ',
    OPENING = 'opening undercity',
    ENTERING = 'entering undercity',
    WAITING = 'waiting ',
}

-- Bargain sub-steps used within open_portal
local BARGAIN = {
    OPEN_MENU = 1,  -- clicked bargain opener, waiting for menu
    SCROLL    = 2,  -- clicked scroll bar, waiting before selecting
    SELECT    = 3,  -- waiting before clicking the option
    READY     = 4,  -- bargain selected (or none available), proceed to tribute+portal
}

local task = {
    name = 'enter_undercity',
    status = status_enum['IDLE'],
    interacted = false,
    debounce_time = -1,
    tribute_applied = false,
    tribute_apply_time = -1,
    -- bargain state
    bargain_step = 0,           -- current BARGAIN.* step (0 = not started)
    bargain_step_time = -1,     -- time when current step began
    bargain_attempt_idx = 0,    -- index into sorted bargain list being tried this interaction
    bargain_walk_away = false,  -- true while walking away to reset obelisk
    portal_click_start = -1,    -- time when we first clicked the portal button this attempt
}

-- Returns bargains sorted by priority (ascending), skipping priority=0
local get_sorted_bargains = function ()
    local result = {}
    for i, bargain in ipairs(gui.bargains_data) do
        local p = settings.bargain_priorities[i]
        if p and p > 0 then
            result[#result + 1] = {idx = i, priority = p, bargain = bargain}
        end
    end
    table.sort(result, function(a, b) return a.priority < b.priority end)
    return result
end

local reset_bargain_state = function ()
    task.bargain_step = 0
    task.bargain_step_time = -1
    task.bargain_attempt_idx = 0
    task.portal_click_start = -1
end

local open_portal = function (delay)
    task.status = status_enum['OPENING']
    local spirit_brazier = utils.get_spirit_brazier()
    if spirit_brazier == nil or spirit_brazier.get_position == nil then return end

    if not loot_manager:is_in_vendor_screen() and not task.interacted then
        interact_object(spirit_brazier)
    elseif not task.interacted then
        task.interacted = true
        task.tribute_applied = false
        task.tribute_apply_time = -1
        reset_bargain_state()
    end

    if loot_manager:is_in_vendor_screen() then
        local now = get_time_since_inject()

        -- ── Bargain selection flow ──────────────────────────────────────────
        if settings.enable_bargains and task.bargain_step < BARGAIN.READY then
            local sorted = get_sorted_bargains()
            -- Advance to the next untried bargain if we haven't started
            if task.bargain_step == 0 then
                task.bargain_attempt_idx = task.bargain_attempt_idx + 1
                if task.bargain_attempt_idx > #sorted then
                    -- All bargains exhausted, skip bargain flow
                    task.bargain_step = BARGAIN.READY
                else
                    -- Click bargain menu opener
                    local cp = settings.bargain_cp['bargain_opener']
                    utility.send_mouse_click(cp.x, cp.y)
                    task.bargain_step = BARGAIN.OPEN_MENU
                    task.bargain_step_time = now
                    task.status = status_enum['WAITING'] .. 'bargain menu'
                end
                return
            end

            local current = sorted[task.bargain_attempt_idx]

            if task.bargain_step == BARGAIN.OPEN_MENU then
                if now < task.bargain_step_time + 0.5 then
                    task.status = status_enum['WAITING'] .. 'bargain menu'
                    return
                end
                if current and current.bargain.needs_scroll then
                    local cp = settings.bargain_cp['scroll_bar']
                    utility.send_mouse_click(cp.x, cp.y)
                    task.bargain_step = BARGAIN.SCROLL
                    task.bargain_step_time = now
                    task.status = status_enum['WAITING'] .. 'scrolling bargains'
                else
                    task.bargain_step = BARGAIN.SELECT
                    task.bargain_step_time = now
                end
                return
            end

            if task.bargain_step == BARGAIN.SCROLL then
                if now < task.bargain_step_time + 0.3 then
                    task.status = status_enum['WAITING'] .. 'scrolling bargains'
                    return
                end
                task.bargain_step = BARGAIN.SELECT
                task.bargain_step_time = now
                return
            end

            if task.bargain_step == BARGAIN.SELECT then
                if now < task.bargain_step_time + 0.3 then
                    task.status = status_enum['WAITING'] .. 'selecting bargain'
                    return
                end
                if current then
                    local cp = settings.bargain_cp[current.bargain.cp_key]
                    utility.send_mouse_click(cp.x, cp.y)
                    task.status = 'bargain: ' .. current.bargain.name
                end
                task.bargain_step = BARGAIN.READY
                task.portal_click_start = -1
                return
            end
        end

        -- ── Tribute + portal flow ───────────────────────────────────────────
        if not task.tribute_applied then
            local lp = get_local_player()
            if lp then
                local key_items = lp:get_dungeon_key_items()
                if key_items and #key_items > 0 then
                    local best_item, best_priority = nil, math.huge
                    for _, item in ipairs(key_items) do
                        local p = settings.tribute_priorities[item:get_sno_id()]
                        if p and p > 0 and p < best_priority then
                            best_item = item
                            best_priority = p
                        end
                    end
                    local chosen = best_item or key_items[1]
                    loot_manager.use_item(chosen)
                    task.tribute_applied = true
                    task.tribute_apply_time = get_time_since_inject()
                    task.portal_click_start = -1
                end
            end
            task.status = status_enum['WAITING'] .. 'applying tribute'
        elseif get_time_since_inject() > task.tribute_apply_time + 0.5 then
            local now = get_time_since_inject()
            -- Check bargain timeout (still in vendor screen after clicking portal)
            if settings.enable_bargains then
                if task.portal_click_start < 0 then
                    task.portal_click_start = now
                elseif now > task.portal_click_start + settings.bargain_timeout then
                    -- Bargain failed — walk away to reset obelisk and retry
                    task.bargain_walk_away = true
                    task.tribute_applied = false
                    task.tribute_apply_time = -1
                    task.bargain_step = 0
                    task.bargain_step_time = -1
                    task.portal_click_start = -1
                    task.status = 'bargain failed - walking away'
                    return
                end
            end
            utility.send_mouse_click(settings.portal_button_x, settings.portal_button_y)
            task.tribute_applied = false
            task.status = status_enum['OPENING']
        else
            task.status = status_enum['WAITING'] .. 'opening portal'
        end
    elseif delay and
        task.debounce_time + settings.confirm_delay > get_time_since_inject()
    then
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

local walk_to_activator = function (activator)
    BatmobilePlugin.set_target(plugin_label, activator)
    BatmobilePlugin.move(plugin_label)
    task.status = status_enum['WALKING'] .. 'spirit brazier'
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

    -- Walk away from obelisk to reset it after a failed bargain
    if task.bargain_walk_away then
        if spirit_brazier == nil or utils.distance(player_pos, spirit_brazier) > 10 then
            task.bargain_walk_away = false
            task.interacted = false
            -- bargain_attempt_idx is intentionally kept so the next attempt starts from the right position
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
            walk_to_activator(spirit_brazier)
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
