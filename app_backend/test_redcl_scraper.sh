#!/bin/bash
# Script para probar el scraper de Red.cl

echo -e "\033[36m🧪 Test del Scraper Red.cl - WayFindCL\033[0m"
echo -e "\033[36m========================================\n\033[0m"

# Verificar que el servidor esté corriendo
SERVER_URL="http://localhost:8080"
echo -e "\033[33m🔍 Verificando servidor en $SERVER_URL...\033[0m"

if curl -s "$SERVER_URL/health" > /dev/null 2>&1; then
    echo -e "\033[32m✅ Servidor activo\033[0m"
else
    echo -e "\033[31m❌ Error: El servidor no está corriendo en $SERVER_URL\033[0m"
    echo -e "\033[33m   Ejecuta: go run cmd/server/main.go\033[0m"
    exit 1
fi

echo -e "\n\033[36m============================================================\033[0m"

# Test 1: Paradero PC615
echo -e "\n\033[36m📍 TEST 1: Consultar paradero PC615\033[0m"
echo -e "\033[90m   Endpoint: GET /api/bus-arrivals/PC615\n\033[0m"

RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" "$SERVER_URL/api/bus-arrivals/PC615")
HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE" | cut -d':' -f2)
BODY=$(echo "$RESPONSE" | sed '/HTTP_CODE/d')

if [ "$HTTP_CODE" = "200" ]; then
    echo -e "\033[32m✅ Respuesta recibida (HTTP $HTTP_CODE)\033[0m"
    
    # Parsear JSON (requiere jq)
    if command -v jq &> /dev/null; then
        STOP_CODE=$(echo "$BODY" | jq -r '.stop_code')
        STOP_NAME=$(echo "$BODY" | jq -r '.stop_name')
        ARRIVALS_COUNT=$(echo "$BODY" | jq '.arrivals | length')
        
        echo -e "   Paradero: \033[1m$STOP_CODE - $STOP_NAME\033[0m"
        echo -e "   \033[33mBuses encontrados: $ARRIVALS_COUNT\033[0m\n"
        
        if [ "$ARRIVALS_COUNT" -gt 0 ]; then
            echo -e "   🚌 Próximas llegadas:"
            echo -e "   \033[90m--------------------------------------------------------\033[0m"
            echo -e "   \033[90mRuta    | Destino              | Distancia | Tiempo  | Estado\033[0m"
            echo -e "   \033[90m--------------------------------------------------------\033[0m"
            
            echo "$BODY" | jq -r '.arrivals[:5] | .[] | "\(.route_number)\t\(.direction)\t\(.distance_km) km\t\(.estimated_minutes) min\t\(.status)"' | while IFS=$'\t' read -r route direction distance time status; do
                printf "   \033[36m%-7s | %-20s | %-9s | %-7s | %s\033[0m\n" "$route" "${direction:0:20}" "$distance" "$time" "$status"
            done
        else
            echo -e "   \033[33m⚠️  No se encontraron buses próximos\033[0m"
        fi
        
        echo -e "\n   \033[90m📄 JSON completo:\033[0m"
        echo "$BODY" | jq '.' | sed 's/^/   /' | sed 's/^/\x1b[90m/' | sed 's/$/\x1b[0m/'
    else
        echo -e "   \033[90m(Instala 'jq' para ver el JSON formateado)\033[0m"
        echo "$BODY"
    fi
else
    echo -e "\033[31m❌ Error HTTP $HTTP_CODE\033[0m"
    echo "$BODY"
fi

echo -e "\n\033[36m============================================================\033[0m"

# Test 2: Paradero PA421
echo -e "\n\033[36m📍 TEST 2: Consultar paradero PA421\033[0m"
echo -e "\033[90m   Endpoint: GET /api/bus-arrivals/PA421\n\033[0m"

RESPONSE2=$(curl -s -w "\nHTTP_CODE:%{http_code}" "$SERVER_URL/api/bus-arrivals/PA421")
HTTP_CODE2=$(echo "$RESPONSE2" | grep "HTTP_CODE" | cut -d':' -f2)
BODY2=$(echo "$RESPONSE2" | sed '/HTTP_CODE/d')

if [ "$HTTP_CODE2" = "200" ]; then
    echo -e "\033[32m✅ Respuesta recibida (HTTP $HTTP_CODE2)\033[0m"
    
    if command -v jq &> /dev/null; then
        STOP_CODE2=$(echo "$BODY2" | jq -r '.stop_code')
        STOP_NAME2=$(echo "$BODY2" | jq -r '.stop_name')
        ARRIVALS_COUNT2=$(echo "$BODY2" | jq '.arrivals | length')
        
        echo -e "   Paradero: \033[1m$STOP_CODE2 - $STOP_NAME2\033[0m"
        echo -e "   \033[33mBuses encontrados: $ARRIVALS_COUNT2\033[0m"
        
        if [ "$ARRIVALS_COUNT2" -gt 0 ]; then
            echo -e "\n   🚌 Primeros 3 buses:"
            echo "$BODY2" | jq -r '.arrivals[:3] | .[] | "      • Ruta \(.route_number): \(.direction)\n        \(.distance_km) km, \(.estimated_minutes) min - \(.status)"'
        fi
    else
        echo "$BODY2"
    fi
else
    echo -e "\033[31m❌ Error HTTP $HTTP_CODE2\033[0m"
fi

echo -e "\n\033[36m============================================================\033[0m"

# Test 3: Paradero inválido
echo -e "\n\033[36m📍 TEST 3: Consultar paradero inválido (XXXXX)\033[0m"
echo -e "\033[90m   Endpoint: GET /api/bus-arrivals/XXXXX\n\033[0m"

RESPONSE3=$(curl -s -w "\nHTTP_CODE:%{http_code}" "$SERVER_URL/api/bus-arrivals/XXXXX")
HTTP_CODE3=$(echo "$RESPONSE3" | grep "HTTP_CODE" | cut -d':' -f2)
BODY3=$(echo "$RESPONSE3" | sed '/HTTP_CODE/d')

if [ "$HTTP_CODE3" != "200" ]; then
    echo -e "\033[32m✅ Error esperado (HTTP $HTTP_CODE3)\033[0m"
    if command -v jq &> /dev/null; then
        echo "$BODY3" | jq '.'
    else
        echo "$BODY3"
    fi
else
    echo -e "\033[33m⚠️  Respuesta inesperada\033[0m"
fi

echo -e "\n\033[36m============================================================\033[0m"
echo -e "\n\033[32m✅ Tests completados\n\033[0m"

# Información adicional
echo -e "\033[33m💡 Paraderos de ejemplo en Santiago:\033[0m"
echo -e "\033[90m   • PC615 - Providencia\033[0m"
echo -e "\033[90m   • PA421 - Las Condes\033[0m"
echo -e "\033[90m   • PI407 - Estación Metro\033[0m"
echo -e "\033[90m   • PB108 - Bellavista\033[0m"
echo -e "\033[90m   • PJ501 - Plaza de Armas\n\033[0m"

echo -e "\033[33m📝 Uso desde curl:\033[0m"
echo -e '\033[90m   curl "http://localhost:8080/api/bus-arrivals/PC615"\n\033[0m'
