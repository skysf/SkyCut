// Clip boundaries, cyclic queue, visible transport time and a continuous full turn.
import test from 'node:test';
import assert from 'node:assert/strict';
import {playbackAt,cardOrder,timecode,turnAt,TURN_SECONDS,REEL_SECONDS} from '../src/scene-playback.js';

test('the footage card changes at the same reel boundary as the playhead',()=>{
  assert.equal(playbackAt(4.999).active,0);
  assert.deepEqual(playbackAt(5),{time:5,active:1,progress:.2,localTime:0});
  assert.equal(playbackAt(10).active,2);
  assert.equal(playbackAt(15).active,3);
  assert.equal(playbackAt(20).active,3);
  assert.equal(playbackAt(24.999).active,3);
  assert.equal(playbackAt(20).localTime,5);
  assert.equal(REEL_SECONDS,25);
  assert.deepEqual(playbackAt(REEL_SECONDS),playbackAt(0));
  assert.deepEqual(playbackAt(REEL_SECONDS+7.5),playbackAt(7.5));
});

test('each active card comes first and the queue never duplicates or drops footage',()=>{
  for(let active=0;active<4;active++){
    const queue=cardOrder(active);
    assert.equal(queue[0],active);
    assert.deepEqual([...queue].sort(),[0,1,2,3]);
    assert.equal(queue[1],(active+1)%4);
  }
});

test('the turntable completes 360 degrees and continues beyond a reel loop',()=>{
  assert.equal(turnAt(TURN_SECONDS),Math.PI*2);
  assert.equal(turnAt(TURN_SECONDS/2),Math.PI);
  assert.ok(turnAt(REEL_SECONDS+.1)>turnAt(REEL_SECONDS));
  assert.ok(turnAt(TURN_SECONDS+.1)>Math.PI*2);
});

test('timecodes follow the silent 20 fps reel without invalid startup values',()=>{
  assert.equal(timecode(5.55),'00:00:05:11');
  assert.equal(timecode(19.999),'00:00:19:19');
  assert.deepEqual(playbackAt(NaN),playbackAt(0));
  assert.deepEqual(playbackAt(-1),playbackAt(0));
});
