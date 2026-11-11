// Español. Los nombres de botones son los de la interfaz en español de la app: Conectar IA, Deshacer esta ronda, Solicitar aprobación, Acceso completo.
export default {
  title:'Cómo editar vídeo con Claude Code en un Mac',
  description:'Claude Code no abre un editor de vídeo por sí solo. Conéctalo a SkyCut en un Mac y cortará, subtitulará y exportará en una línea de tiempo real.',
  heading:'Cómo editar vídeo con Claude Code en un Mac',
  answer:'Claude Code puede editar vídeo cuando tiene un editor que manejar. En un Mac, instala SkyCut, añade tu key de Sky Studio y pulsa **Conectar** junto a Claude Code en los ajustes de SkyCut. A partir de ahí Claude trabaja en una línea de tiempo multipista real a través del servidor MCP local de SkyCut: mira tu material, recorta las pausas del discurso, añade títulos y subtítulos y exporta el resultado, mientras tú ves cada cambio y puedes ajustarlo o deshacerlo. SkyCut funciona en Mac con chip de Apple y macOS 15 o posterior. No hay versión para Windows ni para Intel.',
  sections:[
    {heading:'Qué puede y qué no puede hacer Claude Code con el vídeo',blocks:[
      'Claude Code es un agente de IA que trabaja en tu terminal. Lee archivos y ejecuta comandos, pero no puede ver un vídeo, oír su sonido ni ordenar clips. Para editar necesita una herramienta que lo haga por él. Hay dos tipos.',
      {list:[
        '**Herramientas de línea de comandos.** Claude escribe comandos de FFmpeg o ejecuta una skill que los agrupa. Sirve para tareas con archivos como recortar, unir y convertir. Cada cambio genera un archivo nuevo, y no hay una línea de tiempo que puedas abrir y corregir a mano.',
        '**Un editor de vídeo que Claude puede controlar.** El editor expone su línea de tiempo mediante MCP (Model Context Protocol, la forma estándar de dar herramientas a un asistente de IA). Claude llama a esas herramientas, y cada edición queda en una línea de tiempo que puedes reproducir, recorrer y cambiar tú mismo.',
      ]},
      'SkyCut es del segundo tipo: un editor de vídeo nativo para Mac con un servidor MCP integrado. El resto de esta guía lo utiliza.',
    ]},
    {heading:'Qué necesitas',blocks:[
      {list:[
        'Un Mac con chip de Apple (M1 o posterior) y macOS 15 o posterior. Las funciones que transcriben la voz, como recortar pausas y generar subtítulos, necesitan macOS 26.',
        'SkyCut. La descarga es gratuita.',
        'SkyCut Pro. La edición con IA es una función de Pro. Una prueba de Pro de 7 días empieza la primera vez que conectas SkyCut con tu cuenta de Sky Studio, una vez por cuenta y una vez por Mac.',
        'Claude Code, instalado y con la sesión iniciada con tu propio plan de Claude. SkyCut no incluye ninguna suscripción de IA.',
      ]},
      {note:'Claude Desktop y Codex se conectan en el mismo sitio y funcionan igual. Un chat normal de ChatGPT en el navegador no puede conectarse, porque el servidor MCP de SkyCut se ejecuta en local en tu Mac.'},
    ]},
    {heading:'Configúralo en cinco pasos',blocks:[
      {steps:[
        ['Instala SkyCut','Descarga SkyCut, abre la imagen de disco y arrastra SkyCut a Aplicaciones. La [guía de configuración](/es/docs/#video) tiene un vídeo breve de este paso.'],
        ['Añade tu key de Sky Studio','Inicia sesión en Sky Studio, abre tu avatar arriba a la derecha, elige SkyCut y crea una key. En SkyCut, abre Ajustes, ve a Sky Studio y pega la key. Esto activa Pro y empieza la prueba.'],
        ['Conecta Claude Code','En SkyCut, abre **Ajustes → Conectar IA** y pulsa **Conectar** junto a Claude Code. SkyCut registra su servidor MCP en Claude Code ejecutando `claude mcp add` por ti, y permite las herramientas de SkyCut para que Claude no se detenga a pedir permiso con cada una.'],
        ['Abre una sesión nueva de Claude Code','Claude Code carga los servidores MCP al iniciar una sesión. Abre una sesión nueva y escribe `/mcp`. Deberías ver `skycut` en la lista.'],
        ['Indica a Claude dónde está tu material','Dile a Claude en qué carpeta están tus clips y qué quieres hacer. SkyCut abre esa carpeta, y los archivos nuevos, como las exportaciones, se guardan ahí.'],
      ]},
    ]},
    {heading:'Prompts para una primera edición',blocks:[
      'Hablas con Claude en lenguaje normal. Cada uno de estos prompts corresponde a algo que SkyCut sabe hacer, y puedes usarlos uno tras otro en el mismo proyecto.',
      {prompt:'Abre la carpeta ~/Movies/interview en SkyCut. Mira todos los clips y dime qué hay en cada uno.'},
      {prompt:'Crea un proyecto en 16:9 y monta un primer corte con las tres mejores tomas.'},
      {prompt:'Quita las pausas largas y las muletillas del clip en el que hablo a cámara.'},
      {prompt:'Genera subtítulos en español y añade una traducción al inglés en una segunda pista.'},
      {prompt:'Añade un título que diga Antártida en los tres primeros segundos y exporta un MP4 en 1080p.'},
      'Claude también puede encuadrar a un sujeto, cortar la música al ritmo, superponer y animar clips, añadir una locución e inspeccionar el vídeo final en busca de problemas. Si prefieres no describir cada paso, pide un estilo de edición, como documental o vlog, y deja que planifique el montaje.',
    ]},
    {heading:'Revisa lo que ha hecho Claude',blocks:[
      'Esta es la razón para usar un editor de verdad. Mientras Claude trabaja, SkyCut muestra **La IA está editando** en la barra de herramientas y va saltando a cada cambio en cuanto ocurre. Puedes pulsar **Detener** en cualquier momento.',
      {list:[
        'Cada llamada a una herramienta es un paso de deshacer, así que con ⌘Z retrocedes por las ediciones de Claude una a una.',
        'Cuando Claude termina, **Deshacer esta ronda** devuelve el proyecto a como estaba antes de empezar la ronda.',
        'Nada queda bloqueado. Arrastra un clip, ajusta el tiempo de un subtítulo o cambia un título a mano y luego pide a Claude que siga desde ahí.',
        'SkyCut tiene dos modos de permisos. **Solicitar aprobación** se detiene antes de que Claude vaya más allá de los valores por defecto, por ejemplo antes de borrar un archivo. **Acceso completo** sigue adelante e informa de lo que ha hecho. Los límites diarios de la generación de pago se aplican en ambos.',
      ]},
    ]},
    {heading:'Cuánto cuesta',blocks:[
      {table:{head:['Qué','Precio','Notas'],rows:[
        ['SkyCut Free','{{free.price}}','El editor manual completo. Las exportaciones llevan marca de agua. Sin edición con IA.'],
        ['SkyCut Pro','{{pro.monthly}} al mes o {{pro.yearly}} al año','Edición con IA y exportaciones sin marca de agua. Empieza con una prueba de 7 días la primera vez que conectas SkyCut.'],
        ['Claude Code','Tu propio plan de Claude','Se paga a Anthropic. No forma parte de SkyCut.'],
        ['Generación en la nube','Opcional','Las imágenes, vídeos, música y voces generados consumen créditos de Sky Studio, que se compran aparte.'],
      ]}},
      'Los precios no incluyen impuestos. La lista completa de lo que incluye cada plan está en la [tabla de precios](/es/#pricing).',
    ]},
    {heading:'Límites que conviene conocer antes de empezar',blocks:[
      {list:[
        'Solo Mac: chip de Apple y macOS 15 o posterior. SkyCut no funciona en Windows ni en Mac con Intel.',
        'Claude no ve tu vídeo como lo ves tú. Toma fotogramas, mide niveles y lee transcripciones mediante las herramientas de SkyCut, así que revisa el montaje antes de publicarlo.',
        'Tu proyecto y tu material se quedan en tu Mac, pero Claude recibe lo que devuelven las herramientas, como fotogramas y transcripciones, como parte de vuestra conversación.',
      ]},
    ]},
    {heading:'Otras formas de editar vídeo con Claude',blocks:[
      'SkyCut no es el único camino, y el adecuado depende del trabajo.',
      {list:[
        '**Skills basadas en FFmpeg.** Hay skills de código abierto para Claude Code que agrupan FFmpeg y Whisper y se ejecutan desde la terminal. Encajan con tareas por lotes sobre archivos y no necesitan editor. No hay línea de tiempo que revisar.',
        '**Servidores MCP para otros editores.** Un proyecto de la comunidad controla DaVinci Resolve mediante su API de scripting. Funciona en macOS, Windows y Linux, y el scripting externo requiere la edición Studio de pago de Resolve.',
      ]},
      'Elige SkyCut si trabajas en un Mac y quieres que Claude trabaje en un editor que tú también puedes manejar a mano.',
    ]},
  ],
  faq:[
    ['¿Puede Claude Code editar vídeo por sí solo?','No. Claude Code trabaja con texto y comandos. Para cambiar un vídeo necesita FFmpeg o un editor de vídeo que pueda controlar, como SkyCut.'],
    ['¿Funciona con Claude Desktop o Codex?','Sí. En **Ajustes → Conectar IA**, SkyCut tiene un botón Conectar para Claude Desktop, Claude Code y Codex. Otros clientes funcionan si admiten servidores MCP locales por stdio.'],
    ['¿Es gratis?','SkyCut se descarga gratis y se puede usar a mano sin pagar. Para que edite Claude hace falta SkyCut Pro, a {{pro.monthly}} al mes o {{pro.yearly}} al año cuando termina la prueba de 7 días, además de tu propio plan de Claude.'],
    ['¿Funciona en Windows?','No. SkyCut solo funciona en Mac con chip de Apple y macOS 15 o posterior.'],
    ['¿Se sube mi material?','SkyCut edita en tu Mac y conserva ahí el proyecto. Claude recibe lo que las herramientas devuelven para tu petición, como fotogramas y transcripciones.'],
  ],
};
