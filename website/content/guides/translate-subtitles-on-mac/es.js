// Español. Los nombres de botones son los de la interfaz en español de la app.
export default {
  title:'Traducir subtítulos en Mac y mostrar dos idiomas',
  description:'Traduce un archivo SRT o subtítulos generados en tu Mac, muestra el original y la traducción a la vez y exporta cada idioma. Gratis en SkyCut.',
  heading:'Cómo traducir subtítulos y crear subtítulos bilingües en un Mac',
  answer:'En SkyCut, añade tu vídeo y su archivo de subtítulos a un proyecto, o genera los subtítulos a partir de la voz. Abre el panel de subtítulos, elige un **Idioma de destino** y pulsa **Traducir todo**. La traducción pasa a ser una segunda pista de subtítulos junto al original, y puedes mostrar una de las dos o ambas sobre la imagen. La traducción se hace en tu Mac con Traducción de Apple y necesita macOS 15 o posterior. Al terminar, incrusta uno o los dos idiomas en el vídeo, o exporta un archivo de subtítulos por idioma. Todo esto está en el plan Free. SkyCut solo funciona en Mac con chip de Apple.',
  sections:[
    {heading:'Qué necesitas',blocks:[
      {list:[
        'Un Mac con chip de Apple y macOS 15 o posterior. Traducir no necesita macOS 26. Solo lo necesita generar subtítulos a partir de la voz.',
        'SkyCut. La descarga es gratuita, y traducir a mano no requiere cuenta.',
        'Subtítulos que traducir: un archivo de subtítulos como SRT, WebVTT o ASS, o los subtítulos que SkyCut haya generado a partir del vídeo.',
      ]},
    ]},
    {heading:'Traduce en cuatro pasos',blocks:[
      {steps:[
        ['Añade el vídeo y los subtítulos','Crea un proyecto y arrastra el vídeo. Después usa **Añadir archivo de subtítulos…** para adjuntar tu archivo. Si no tienes archivo, genera primero los subtítulos desde el mismo panel con **Generar subtítulos**, lo que requiere macOS 26.'],
        ['Abre el panel de subtítulos','Pulsa el botón de subtítulos de la barra de herramientas. Su ayuda dice **Generar, traducir y editar pistas de subtítulos**.'],
        ['Elige el idioma','En **Traducir**, elige el **Idioma de destino**. Si un idioma aparece marcado como pendiente de descarga, macOS lo descarga la primera vez.'],
        ['Pulsa Traducir todo','La traducción aparece como una pista de subtítulos propia. El original no cambia.'],
      ]},
    ]},
    {heading:'Revisa y corrige la traducción',blocks:[
      {list:[
        'La traducción automática falla con nombres, jerga y bromas. Lee la pista traducida una vez y haz clic en cualquier línea para reescribirla.',
        'Las dos pistas son independientes. Puedes cambiar el texto o el tiempo de una línea traducida sin tocar el original.',
        'Si más tarde cambias el original, **Traducir faltantes y desactualizadas** traduce solo las líneas nuevas o cuyo original ha cambiado, y deja el resto como está.',
      ]},
    ]},
    {heading:'Muestra un idioma o dos',blocks:[
      {table:{head:['Quieres','Pon la pista en la previsualización en','Lo que ves'],rows:[
        ['Solo el original','**Texto original**','Una línea de subtítulos en el idioma de origen'],
        ['Solo la traducción','**Texto traducido**','Una línea de subtítulos en el idioma de destino'],
        ['Los dos a la vez','**Bilingüe**','La traducción justo debajo del original'],
      ]}},
      'En la vista bilingüe las dos líneas se mueven como un bloque. Arrastra una de ellas sobre la imagen y se separan, de modo que puedes dejar el original abajo y la traducción arriba, por ejemplo.',
    ]},
    {heading:'Exporta cada idioma',blocks:[
      {list:[
        '**Incrustados.** Marca **Incrustar los subtítulos en el video** en el panel de exportación. Se dibujan sobre la imagen las pistas que estén visibles, así que muestra las dos para subtítulos bilingües u oculta una para un solo idioma.',
        '**Como archivos.** **Exportar archivos de subtítulos** escribe un archivo por idioma junto al vídeo. El idioma forma parte del nombre del archivo, y así es como los reproductores y las plataformas distinguen las pistas.',
        '**Varias versiones.** Exporta el vídeo una vez sin incrustar y luego exporta los archivos de subtítulos. Un vídeo y un archivo por idioma sirven para cualquier plataforma que acepte archivos de subtítulos.',
      ]},
    ]},
    {heading:'O pídeselo a un asistente de IA',blocks:[
      'Con SkyCut Pro, Claude o Codex pueden hacer todo el trabajo con una sola petición. Conecta el asistente como se explica en [la guía de Claude Code](/es/guides/edit-video-with-claude-code/).',
      {prompt:'Traduce los subtítulos al inglés y al japonés, y exporta un archivo de subtítulos por idioma.'},
      'Un proyecto conserva una sola traducción a la vez, así que el asistente traduce y exporta un idioma tras otro. Usa la misma traducción en el dispositivo que el panel.',
    ]},
    {heading:'Límites que conviene conocer',blocks:[
      {list:[
        'Los pares de idiomas que puedes traducir son los que macOS ofrece en tu Mac.',
        'Un proyecto contiene el original y una traducción a la vez. Para varios idiomas, traduce, exporta el archivo de subtítulos y traduce al siguiente idioma.',
        'Los vídeos exportados con el plan Free llevan marca de agua. Los archivos de subtítulos no llevan ninguna.',
        'SkyCut es solo para Mac: chip de Apple y macOS 15 o posterior, sin versión para Windows ni para Intel.',
      ]},
    ]},
  ],
  faq:[
    ['¿Es gratis traducir subtítulos en SkyCut?','Sí. Traducir, editar y exportar subtítulos a mano forma parte del plan Free y no requiere cuenta.'],
    ['¿Se envían mis subtítulos a un servidor?','No. La traducción se ejecuta en tu Mac con Traducción de Apple. macOS puede descargar un idioma la primera vez.'],
    ['¿Puedo traducir un archivo SRT que ya tengo?','Sí. Añade el vídeo, adjunta el archivo con **Añadir archivo de subtítulos…** y tradúcelo. Se conserva el tiempo de cada línea.'],
    ['¿Cómo consigo subtítulos bilingües en el vídeo?','Traduce, muestra las dos pistas poniendo la pista en la previsualización en **Bilingüe** y marca **Incrustar los subtítulos en el video** al exportar.'],
    ['¿Necesita macOS 26?','No. La traducción funciona en macOS 15 o posterior. Solo generar subtítulos a partir de la voz necesita macOS 26.'],
  ],
};
