# Ibb OpenStreetMap Collector

يجمع المحلات والخدمات المعلّمة في OpenStreetMap داخل صندوق دراسة إب عبر Overpass.

## التشغيل
~~~bash
pip install -r requirements.txt
python collector.py --dry-run
python collector.py --output-dir output
~~~

الصندوق الافتراضي:
13.92 <= latitude <= 14.03
44.12 <= longitude <= 44.25

هذا صندوق دراسة تقريبي وليس حدًا إداريًا رسميًا.

بيانات OSM مرخصة وفق ODbL. الأداة لا تنزل بلاطات OSM ولا تنفذ كشطًا لواجهة الخرائط. يجب استخدام User-Agent واضح واحترام حدود الخدمة. لا تُفترض رخصة صور المواقع الخارجية من رخصة بيانات OSM.
