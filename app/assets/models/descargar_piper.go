package main

import (
	"fmt"
	"io"
	"net/http"
	"os"
)

func main() {
	fmt.Println("============================================================")
	fmt.Println("   Descargador de Modelos Piper TTS (2024)")
	fmt.Println("============================================================")
	fmt.Println()

	// Modelo español de alta calidad optimizado para móviles
	// es_ES-sharvard-medium: Voz femenina española, calidad alta, ~30MB
	// Fuente: Hugging Face (más actualizado que GitHub Releases)
	models := map[string]string{
		"piper_es.onnx":       "https://huggingface.co/rhasspy/piper-voices/resolve/main/es/es_ES/sharvard/medium/es_ES-sharvard-medium.onnx",
		"piper_es.onnx.json": "https://huggingface.co/rhasspy/piper-voices/resolve/main/es/es_ES/sharvard/medium/es_ES-sharvard-medium.onnx.json",
	}

	for filename, url := range models {
		if fileExists(filename) {
			fmt.Printf("⏭️  %s ya existe\n", filename)
			continue
		}

		fmt.Printf("📥 Descargando: %s\n", filename)
		fmt.Printf("   Desde: %s\n", url)

		err := downloadFile(url, filename)
		if err != nil {
			fmt.Printf("❌ Error: %v\n\n", err)
			continue
		}

		info, _ := os.Stat(filename)
		fmt.Printf("✅ Descargado: %.2f MB\n\n", float64(info.Size())/(1024*1024))
	}

	fmt.Println("============================================================")
	fmt.Println("✅ Modelos Piper descargados")
	fmt.Println("============================================================")
	fmt.Println()
	fmt.Println("📝 Siguiente paso: Convertir ONNX a TFLite")
	fmt.Println()
	fmt.Println("   Opción A (Python temporal):")
	fmt.Println("     pip install onnx2tf")
	fmt.Println("     onnx2tf -i piper_es.onnx -o piper_es.tflite")
	fmt.Println()
	fmt.Println("   Opción B (Usar ONNX directamente en Android):")
	fmt.Println("     Cambiar NeuralTtsPlugin.kt para usar ONNX Runtime")
	fmt.Println()
}

func downloadFile(url, filepath string) error {
	client := &http.Client{}
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return err
	}

	req.Header.Set("User-Agent", "Mozilla/5.0")
	req.Header.Set("Accept", "application/octet-stream,*/*")

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}

	out, err := os.Create(filepath)
	if err != nil {
		return err
	}
	defer out.Close()

	_, err = io.Copy(out, resp.Body)
	return err
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
