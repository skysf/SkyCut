"""只含原创合成故事的公开 film DTO；实际邻居引用由 MCP prepare_references 回填。"""
from copy import deepcopy


def story(inputs, prepared_render=None):
    context = dict(environment="interior", light_source="practical", shot_task="read_action")
    state = dict(actor_position="beside table", hand="right", grip="holding lantern", prop_location="right hand",
                 action_phase="paused", spatial_relation="table ahead", gaze="at switch", screen_direction="right",
                 lighting="single lamp", completed_actions=["arrive"])
    render = dict(kind="image_to_video", model="minimax-h3", prompt="An original blue room with a still lamp.",
                  params=dict(duration=3, resolution="768p", mode="frames"), inputs=inputs, context=context)
    if prepared_render is not None:
        render = {**deepcopy(prepared_render), "context": context}
    return deepcopy(dict(intent="original_film", category="science_fiction", footage="none", context=context,
                         shot=dict(id="shot-b", index=1, total=3, revision=1, entry=state, exit=state, actions=[]),
                         sound=dict(bed_id="room-air", music="restrained pulse", environment="continuous ventilation",
                                    foley="none while still"),
                         previous=dict(shot_id="shot-a", render=render, sound_bed_id="room-air", cut=dict(type="continuous"), exit=state),
                         next=dict(shot_id="shot-c", render=render, sound_bed_id="room-air", cut=dict(type="continuous"), entry=state)))
