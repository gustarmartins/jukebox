import random
import pytest


def simulate_shuffle_upcoming(pl_data, cur_pos=None):
    """
    Python logic mirroring _jukebox_shuffle_upcoming
    """
    if not pl_data or len(pl_data) <= 1:
        return pl_data, []

    if cur_pos is None:
        for i, e in enumerate(pl_data):
            if e.get("current"):
                cur_pos = i
                break
        if cur_pos is None:
            cur_pos = 0

    n = len(pl_data)
    if n - (cur_pos + 1) <= 1:
        return pl_data, []

    current_order = [e.get("id") for e in pl_data]
    upcoming_ids = list(current_order[cur_pos + 1:])
    random.shuffle(upcoming_ids)
    target_order = current_order[:cur_pos + 1] + upcoming_ids

    state = list(current_order)
    moves = []
    for target_pos in range(cur_pos + 1, n):
        target_id = target_order[target_pos]
        curr_pos_of_id = state.index(target_id)
        if curr_pos_of_id != target_pos:
            moves.append({"command": ["playlist-move", curr_pos_of_id, target_pos]})
            item = state.pop(curr_pos_of_id)
            state.insert(target_pos, item)

    return state, moves


def simulate_clear_upcoming(pl_data, cur_pos=None):
    """
    Python logic mirroring clear_script in _jukebox_queue_picker
    """
    if not pl_data:
        return []

    if cur_pos is None:
        for i, e in enumerate(pl_data):
            if e.get("current"):
                cur_pos = i
                break
        if cur_pos is None:
            cur_pos = 0

    n = len(pl_data)
    removes = []
    for idx in range(n - 1, cur_pos, -1):
        removes.append({"command": ["playlist-remove", idx]})

    return removes


def test_shuffle_upcoming_preserves_current_and_past():
    # 10 items, currently playing item 3 (0-indexed)
    pl_data = [{"id": i, "filename": f"song{i}.flac", "current": (i == 3)} for i in range(10)]
    
    shuffled_state, moves = simulate_shuffle_upcoming(pl_data, cur_pos=3)
    
    # Items 0..3 must remain identical
    assert shuffled_state[:4] == [0, 1, 2, 3]
    # Items 4..9 must contain exactly elements {4..9} in some permutation
    assert set(shuffled_state[4:]) == {4, 5, 6, 7, 8, 9}
    assert len(shuffled_state) == 10


def test_shuffle_upcoming_minimal_moves():
    for _ in range(20):
        pl_data = [{"id": i, "filename": f"song{i}.flac", "current": (i == 2)} for i in range(15)]
        shuffled_state, moves = simulate_shuffle_upcoming(pl_data, cur_pos=2)
        assert shuffled_state[:3] == [0, 1, 2]
        assert set(shuffled_state[3:]) == set(range(3, 15))


def test_shuffle_upcoming_edge_cases():
    # Empty
    assert simulate_shuffle_upcoming([]) == ([], [])
    
    # Single item
    single = [{"id": 1, "filename": "single.flac", "current": True}]
    assert simulate_shuffle_upcoming(single) == (single, [])
    
    # Current is last item (0 upcoming)
    last_cur = [{"id": 1, "filename": "1.flac"}, {"id": 2, "filename": "2.flac", "current": True}]
    assert simulate_shuffle_upcoming(last_cur) == (last_cur, [])
    
    # Only 1 upcoming item
    one_up = [{"id": 1, "filename": "1.flac", "current": True}, {"id": 2, "filename": "2.flac"}]
    assert simulate_shuffle_upcoming(one_up) == (one_up, [])


def test_clear_upcoming_removes_in_reverse():
    pl_data = [{"id": i, "filename": f"song{i}.flac", "current": (i == 2)} for i in range(6)]
    removes = simulate_clear_upcoming(pl_data, cur_pos=2)
    # Must remove 5, then 4, then 3
    assert removes == [
        {"command": ["playlist-remove", 5]},
        {"command": ["playlist-remove", 4]},
        {"command": ["playlist-remove", 3]},
    ]
