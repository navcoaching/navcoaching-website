(()=>{"use strict";module.exports=[27927,r=>r.a(async(t,e)=>{try{var i=r.i(43793),a=t([i]);async function o(r){return(0,i.g)(r,async t=>(await t.query(`SELECT o.order_no,
            EXISTS (SELECT 1 FROM blocks b WHERE b.order_id = o.id) AS training,
            (EXISTS (SELECT 1 FROM nutrition_targets t WHERE t.order_id = o.id)
              OR EXISTS (SELECT 1 FROM nutrition_plans p WHERE p.order_id = o.id AND NOT p.archived)
              OR EXISTS (SELECT 1 FROM supplement_routines r WHERE r.order_id = o.id AND NOT r.archived)) AS nutrition
       FROM orders o
      WHERE o.user_id = $1 AND o.category = 'follow' AND o.status IN ('active', 'delivered', 'completed')
      ORDER BY (o.status = 'active') DESC, o.sub_start_at DESC NULLS LAST, o.created_at DESC LIMIT 1`,[r])).rows[0])}[i]=a.then?(await a)():a,r.s(["f",0,o]),e()}catch(r){e(r)}},!1),3073,r=>{let t={breakfast:"الفطور",lunch:"الغداء",dinner:"العشاء",snack:"سناك"},e=r=>4*Number(r.protein)+4*Number(r.carbs)+9*Number(r.fat),i=r=>Math.round(10*r)/10;r.s(["p",0,t,"V",0,e,"M",0,function(r,e,i){let a=t[r],o=e.trim(),n=o.split(/\s+[—–]\s+|\s*:\s*/).map(r=>r.trim()).filter(r=>r&&r!==a);if(n.length)return n[n.length-1];let s=(i??"").split("،").map(r=>r.trim()).filter(Boolean);return s.length?s.slice(0,3).join(" + "):o},"A",0,function(r){let t=r.reduce((r,t)=>({protein:r.protein+Number(t.protein),carbs:r.carbs+Number(t.carbs),fat:r.fat+Number(t.fat)}),{protein:0,carbs:0,fat:0});return{protein:i(t.protein),carbs:i(t.carbs),fat:i(t.fat),kcal:i(e(t))}}])}]})();

//# sourceMappingURL=src_lib_1bndamc05wbcf._.js.map