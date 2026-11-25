# Registro de cambios

Estas son las notas de versión de Zigzag en español, traducidas de CHANGELOG.md. La app muestra las notas de la versión que usas, y [zigzagbrowser.com/release-notes](https://zigzagbrowser.com/release-notes) muestra todas las versiones. Las versiones anteriores a la 0.10.0 están en inglés en [CHANGELOG.md](../../../CHANGELOG.md).

## [Unreleased]

## [0.10.0] - 2026-11-25

Zigzag en trece idiomas más, del japonés y el coreano al alemán, el francés, el español y el ruso; reglas de descarga que envían el archivo guardado; carpetas dinámicas que dicen cuándo se actualizaron por última vez, y escribir en pinyin chino y pasar al inglés sin espacios de más.

### Nuevo
- Zigzag ya está en japonés, con los términos japoneses de Apple para macOS y Safari. Sigue el idioma de tu Mac, o elígelo en Ajustes › General › Idioma.
- Zigzag ya está en coreano, alemán, francés, italiano, español, portugués de Brasil, ruso, neerlandés, polaco y turco, con los términos de Apple en cada idioma. Sigue el idioma de tu Mac, o elige uno en Ajustes › General › Idioma.
- Una regla de descarga puede enviar el archivo en lugar de la dirección: pon Enviar en Archivo y Zigzag primero lo descarga con la sesión de la página y después pasa el archivo guardado a la app, el script o el servicio. Los enlaces siguen enviando su dirección, y las plantillas de un envío de archivo pueden usar {file} o {file_url} para el archivo guardado. Gracias a [Lakeland97](https://github.com/Lakeland97). ([#529](https://github.com/ZigaoWang/zigzag/issues/529))
- El menú de una carpeta dinámica ahora empieza con la hora de la última actualización, como Actualizado hace 5 minutos, o Actualizando… mientras se descarga.
- Las ventanas Nueva carpeta dinámica y Editar carpeta dinámica piden primero la fuente, alinean sus menús con los campos y explican debajo qué mostrará la carpeta y que se comprueba cada 30 minutos (cada hora en modo de bajo consumo). Si dejas el nombre vacío, se ve el nombre que recibirá, y se marca un nombre de usuario que GitHub no admite.

### Correcciones
- Con Zigzag Mini abierto sobre una página, desplazarte sobre la página atenuada ya no mueve la página de detrás. Gracias a [Lakeland97](https://github.com/Lakeland97). ([#531](https://github.com/ZigaoWang/zigzag/pull/531))
- La explicación antes de permitir que los sitios web accedan a apps de este Mac ahora da los pasos en orden: activa el ajuste, después activa cada sitio en sus Ajustes del sitio, y al desactivar el ajuste se detienen todos los sitios. Gracias a [Lakeland97](https://github.com/Lakeland97). ([#533](https://github.com/ZigaoWang/zigzag/issues/533))
- En Ajustes, una lista bajo un encabezado con botones o una búsqueda al lado, como Almacenado por sitios web o Enviar descargas y enlaces, ya no empieza justo debajo de esos controles. Deja debajo de ellos el mismo espacio que cualquier otro encabezado. Gracias a [Lakeland97](https://github.com/Lakeland97). ([#527](https://github.com/ZigaoWang/zigzag/issues/527))
- Pasar del pinyin chino al inglés a mitad de palabra ya no deja espacios entre las letras, en una página o en la barra de direcciones, como en Chrome.
- Un espacio con transparencia y cristal Transparente ya no mantiene ocupados los gráficos del Mac mientras Zigzag está quieto, ni siquiera en una página en blanco o en Ajustes. macOS volvía a dibujar toda la ventana y su sombra en cada fotograma; ahora solo la dibuja cuando algo cambia. La barra de progreso de la tarjeta de actualización también deja de moverse mientras está oculta.
