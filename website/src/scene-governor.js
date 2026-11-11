// Frame-time budget for the live scene. Pure values only, without DOM or WebGL state.
// A device that cannot keep up first renders fewer pixels, then hands the picture back to the still.
export const PIXEL_RATIOS=[2,1.5,1];
// 40 ms lets a 30 Hz display (and iOS Low Power Mode) pass; under 25 fps does not.
export const FRAME_BUDGET=40;
// Over budget for this long, after a short warm-up, before anything changes (milliseconds).
export const FRAME_PATIENCE=3000,FRAME_WARMUP=500;
// One long frame counts as this much at most, so a single stall fades from the average at once.
export const FRAME_STALL=250;
// Displays faster than ~95 Hz skip frames so the scene never renders more than it needs.
export const FRAME_FLOOR=10.5;

export function createGovernor(){
  const last=PIXEL_RATIOS.length-1;
  let level=0,average=0,warm=0,over=0;
  const settle=()=>{average=0;warm=0;over=0;};
  return {
    get level(){return level;},
    get pixelRatio(){return PIXEL_RATIOS[level];},
    // Call after a pause, a hidden tab or a resize: the next frames say nothing about the scene.
    settle,
    // One rendered frame took `ms` since the previous one: 'ok', 'lower' the pixel ratio, or 'stop'.
    sample(ms){
      if(!(ms>0))return 'ok';
      const capped=Math.min(ms,FRAME_STALL);
      if((warm+=capped)<=FRAME_WARMUP)return 'ok';
      average=average?average*.9+capped*.1:capped;
      over=average>FRAME_BUDGET?over+capped:0;
      if(over<FRAME_PATIENCE)return 'ok';
      // Far over budget: one step would not be enough, go straight to the fewest pixels.
      const crawling=average>FRAME_BUDGET*2.5;
      settle();
      if(level<last){level=crawling?last:level+1;return 'lower';}
      return 'stop';
    }
  };
}

// Whether the animated scene may run at all. Anything else keeps the baked still on screen.
export function wantsLiveScene({webgl2,reducedMotion}){
  return Boolean(webgl2)&&!reducedMotion;
}
